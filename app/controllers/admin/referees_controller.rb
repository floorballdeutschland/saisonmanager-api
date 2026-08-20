module Admin
  class RefereesController < ApplicationController
    include RefereeScoping

    before_action :authorize_referee_access!

    MAX_CSV_BYTES = 5 * 1024 * 1024
    # application/octet-stream ist dabei, weil Browser das für eine .csv real so
    # schicken (Drag-and-drop, Windows ohne registrierte Zuordnung). Ohne den
    # Eintrag wird eine einwandfreie Datei mit „Unzulässiger Datei-Typ" abgewiesen,
    # was wie ein kaputter Export aussieht. Der Inhalt wird ohnehin geparst.
    ALLOWED_CSV_CONTENT_TYPES = %w[text/csv text/plain application/vnd.ms-excel application/csv
                                   text/comma-separated-values application/octet-stream].freeze
    before_action :set_referee,
                  only: %i[show update destroy games club_stats partners merge create_user destroy_user feedbacks]

    # Tranchengröße der Massenanlage. Bewusst klein: Der Aufruf legt höchstens so
    # viele Konten an und meldet zurück, wie viele offen bleiben — ein zweiter
    # Klick nimmt die nächste Tranche. Damit gehen je Aufruf höchstens 100
    # Willkommensmails raus (nicht insgesamt: zwei Klicks sind 200), und ein
    # Fehlgriff trifft nicht den ganzen Bestand.
    MAX_BULK_USER_CREATIONS = 100

    # GET /api/v2/admin/referees
    def index
      unless valid_status_filter?
        return render json: { errors: ["Unbekannter Status-Filter: #{params[:status]}"] },
                      status: :unprocessable_entity
      end

      referees = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type,
                                  referee_taggings: :referee_tag)
      # Das Konto-Badge braucht die Verknüpfung je Zeile; ohne includes wäre das
      # eine Query pro Schiedsrichter. Nur laden, wenn es auch ausgeliefert wird.
      referees = referees.includes(:user) if can_view_contact_data?

      referees = scope_to_permitted_referees(referees)

      referees = referees.search(params[:q]) if params[:q].present?
      referees = referees.by_landesverband(params[:landesverband]) if params[:landesverband].present?
      referees = referees.by_lizenzstufe(params[:lizenzstufe]) if params[:lizenzstufe].present?
      referees = apply_license_status_filter(referees)
      if params[:tag_id].present?
        referees = referees.where(id: RefereeTagging.where(referee_tag_id: params[:tag_id]).select(:referee_id))
      end

      sort_col = params[:sort] == 'lizenznummer' ? 'lizenznummer' : 'nachname'
      sort_dir = params[:sort_dir] == 'desc' ? 'DESC' : 'ASC'
      referees = if sort_col == 'lizenznummer'
                   referees.order(Arel.sql("lizenznummer #{sort_dir} NULLS LAST"))
                 else
                   referees.order(Arel.sql("nachname #{sort_dir}, vorname #{sort_dir}"))
                 end

      referees = referees.to_a
      counts = season_game_counts(referees)
      contact = can_view_contact_data?
      render json: referees.map { |r| referee_json(r, season_game_count: counts[r.lizenznummer].to_i, contact:) }
    end

    # GET /api/v2/admin/referees/:id
    def show
      return forbidden_response unless can_access_referee?(@referee)

      render json: referee_json(@referee, full: true)
    end

    # GET /api/v2/admin/referees/:id/feedbacks
    # Schiri-Feedback der Vereine zu diesem Schiedsrichter. Nur für Admin,
    # FD-RSK (global) und FD-Ansetzer (global) sichtbar.
    def feedbacks
      return forbidden_response unless can_view_feedback?

      feedbacks = RefereeFeedback
                  .for_referee(@referee.id)
                  .includes(:team, game: { game_day: :league })
                  .order(created_at: :desc)

      visible = feedbacks.select(&:visible?)
      render json: {
        summary: {
          count: visible.size,
          avg_line_rating: average_rating(visible, :line_rating),
          avg_communication_rating: average_rating(visible, :communication_rating)
        },
        feedbacks: feedbacks.map { |f| feedback_json(f) }
      }
    end

    # POST /api/v2/admin/referees
    def create
      return forbidden_response unless can_create_referee?

      referee = Referee.new(safe_referee_params)
      referee.game_operation_id = assigned_game_operation_id if restricted_user? && referee.game_operation_id.blank?

      if referee.save
        sync_qualifications(referee) if can_edit_full?
        sync_tags(referee) if can_manage_tags?
        render json: referee_json(referee.reload, full: true), status: :created
      else
        render json: { errors: referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referees/:id
    def update
      return forbidden_response unless can_access_referee?(@referee, include_vm: false)

      @referee.assign_attributes(safe_referee_params)
      license_fields_changed = (@referee.changed & %w[lizenznummer gueltigkeit lizenzstufe]).any?
      notify = @referee.email.present? && license_fields_changed && !@referee.guest?

      if @referee.save
        sync_qualifications(@referee) if can_edit_full?
        sync_tags(@referee) if can_manage_tags?
        RefereeMailer.license_notification(@referee).deliver_later if notify
        render json: referee_json(@referee.reload, full: true)
      else
        render json: { errors: @referee.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referees/:id
    def destroy
      return forbidden_response unless can_edit_full?

      # Benutzerkonten löschen ist Admin-only (wie users#destroy/destroy_user).
      # Ein FD-RSK löscht nur den Schiri-Datensatz; ein verknüpftes Konto wird
      # entkoppelt (users.referee_id ist FK-geschützt) und bleibt bestehen.
      user = @referee.user
      if user && user.id != current_user.id && current_user.permission_hash[:admin].present?
        user.destroy
      elsif user
        user.update_column(:referee_id, nil)
      end
      @referee.destroy
      head :no_content
    end

    # POST /api/v2/admin/referees/:id/merge
    def merge
      return forbidden_response unless can_access_referee?(@referee, include_vm: false)

      secondary = Referee.find_by(id: params[:secondary_id])
      return render json: { message: 'Secondary-Schiedsrichter nicht gefunden.' }, status: :not_found unless secondary
      return forbidden_response unless can_access_referee?(secondary, include_vm: false)

      secondary.merge_into!(@referee, current_user.id)
      render json: { message: 'Schiedsrichter erfolgreich zusammengeführt.', master_id: @referee.id }
    rescue ArgumentError => e
      render json: { message: e.message }, status: :unprocessable_entity
    end

    # GET /api/v2/admin/referees/:id/games
    def games
      return forbidden_response unless can_access_referee?(@referee)

      season_id = params[:season_id]
      games = @referee.games(season_id: season_id)
                      .includes(:home_team, :guest_team, game_day: :league)
                      .joins(:game_day)
                      .order('game_days.date DESC')

      render json: games.map { |g| game_summary(g) }
    end

    # GET /api/v2/admin/referees/:id/partners
    # Gespann-Historie: mit wem dieser Schiri tatsächlich im Einsatz war.
    # include_vm: false, weil das anders als games/club_stats keine Sicht auf
    # den eigenen Verein ist, sondern eine Bestandsauswertung, die bewusst auch
    # Partner aus anderen Verbänden zeigt. Sie bleibt RSK/Ansetzern vorbehalten.
    def partners
      return forbidden_response unless can_access_referee?(@referee, include_vm: false)

      render json: @referee.partner_history
    end

    # GET /api/v2/admin/referees/:id/club_stats
    def club_stats
      return forbidden_response unless can_access_referee?(@referee)

      season_id = params[:season_id]

      games = @referee.games(season_id: season_id)
                      .includes(
                        game_day: :league,
                        home_team: :club,
                        guest_team: :club
                      )

      counts = Hash.new(0)
      club_names = {}

      games.each do |game|
        s = game.game_day.league&.season_id
        [game.home_team&.club, game.guest_team&.club].compact.each do |club|
          key = [club.id, s]
          counts[key] += 1
          club_names[club.id] = club.name
        end
      end

      result = counts.map do |(club_id, s), count|
        { club_id:, club_name: club_names[club_id], season_id: s, game_count: count }
      end

      result.sort_by! { |r| [-r[:game_count], r[:club_name].to_s] }

      render json: result
    end

    # GET /api/v2/admin/referees/next_lizenznummer
    def next_lizenznummer
      return forbidden_response unless can_create_referee?

      max = Referee.where(guest: false).maximum(:lizenznummer) || 0
      render json: { next_lizenznummer: max + 1 }
    end

    # GET /api/v2/admin/referees/incorrect_assignments
    # POST /api/v2/admin/referees/:id/create_user
    # Legt ein Schiedsrichter-Benutzerkonto an und verknüpft es mit dem Referee.
    def create_user
      return forbidden_response unless can_create_referee_login?
      return forbidden_response unless can_access_referee?(@referee)

      # Die fachlichen Vorbedingungen (Konto vorhanden, E-Mail fehlt) und der
      # Aufbau des Kontos liegen im Service, damit Einzel- und Massenanlage nicht
      # auseinanderlaufen. Das Admin-UI blockt die fehlende E-Mail zusätzlich
      # clientseitig.
      result = RefereeAccountCreator.new(@referee).call
      unless result.success?
        return render json: { error: result.error }, status: :unprocessable_entity
      end

      render json: referee_json(@referee.reload, full: true)
                   .merge(email_sent: result.email_sent, duplicate_email: result.duplicate_email)
    end

    # POST /api/v2/admin/referees/import_emails
    # Trägt E-Mail-Adressen aus einer CSV („Lizenznummer";„E-Mailadresse") in
    # bestehende Schiedsrichter-Profile ein — nur dort, wo noch keine steht.
    def import_emails
      return forbidden_response unless can_manage_account_tools?

      file = params[:file]
      return render(json: { error: 'CSV-Datei fehlt' }, status: :unprocessable_entity) if file.blank?

      # Ein Nicht-Datei-Parameter (String, Array) käme durch beide Prüfungen unten
      # durch — String#size gibt es, content_type nicht — und stürbe erst am
      # `read` im 500er.
      unless file.respond_to?(:read)
        return render(json: { error: 'Der Parameter "file" enthält keine Datei.' },
                      status: :unprocessable_entity)
      end

      if file.respond_to?(:size) && file.size > MAX_CSV_BYTES
        return render(json: { error: "Datei zu groß (max. #{MAX_CSV_BYTES / 1024 / 1024} MB)" },
                      status: :unprocessable_entity)
      end

      content_type = file.respond_to?(:content_type) ? file.content_type.to_s.split(';').first : nil
      if content_type.present? && ALLOWED_CSV_CONTENT_TYPES.exclude?(content_type)
        return render(json: { error: "Unzulässiger Datei-Typ (#{content_type}). Erwartet wird CSV." },
                      status: :unprocessable_entity)
      end

      import = RefereeEmailImport.new(csv_content: file.read)
      report = import.call
      return render(json: { error: import.errors.join(' ') }, status: :unprocessable_entity) if report.nil?

      render json: report
    end

    # GET /api/v2/admin/referees/missing_user_count
    # Zählt die Schiedsrichter, für die die Massenanlage ein Konto erzeugen würde.
    def missing_user_count
      return forbidden_response unless can_manage_account_tools?

      render json: { count: RefereeAccountCreator.candidates.count, batch_size: MAX_BULK_USER_CREATIONS }
    end

    # POST /api/v2/admin/referees/create_missing_users
    # Legt für Schiedsrichter mit E-Mail, aber ohne Konto, Benutzerkonten an —
    # höchstens MAX_BULK_USER_CREATIONS je Aufruf, der Rest über `remaining`.
    def create_missing_users
      return forbidden_response unless can_manage_account_tools?

      candidates = RefereeAccountCreator.candidates
      total = candidates.count
      # includes(:user): Der Service prüft je Datensatz auf ein vorhandenes Konto,
      # das wären sonst 100 Einzelqueries je Klick.
      batch = candidates.includes(:user).order(:lizenznummer).limit(MAX_BULK_USER_CREATIONS).to_a

      created = []
      failed = []
      batch.each { |referee| create_account_for(referee, created, failed) }

      # remaining zählt die Fehlgeschlagenen mit: Sie erfüllen die Bedingungen
      # weiter und tauchen beim nächsten Aufruf wieder auf. Bleibt ein Datensatz
      # dauerhaft hängen (etwa weil sein Benutzername schon belegt ist), sinkt die
      # Zahl also nicht — die Fehlerliste benennt den Grund je Datensatz.
      render json: { requested: batch.size, created: created, failed: failed,
                     remaining: total - created.size, batch_size: MAX_BULK_USER_CREATIONS }
    end

    # DELETE /api/v2/admin/referees/:id/destroy_user
    # Löscht das verknüpfte Benutzerkonto eines Schiedsrichters vollständig.
    # Bewusst Admin-only (wie users#destroy) — Anlegen darf auch der RSK,
    # das Löschen eines Benutzer-Datensatzes bleibt der Verwaltung vorbehalten.
    def destroy_user
      return forbidden_response unless current_user.permission_hash[:admin].present?

      user = @referee.user
      if user.nil?
        return render json: { error: 'Diesem Schiedsrichter ist kein Benutzerkonto zugeordnet.' },
                      status: :unprocessable_entity
      end
      if user.id == current_user.id
        return render json: { error: 'Eigenes Konto kann nicht gelöscht werden.' }, status: :forbidden
      end

      user.destroy!
      render json: referee_json(@referee.reload, full: true)
    rescue ActiveRecord::InvalidForeignKey
      render json: { error: 'Benutzerkonto kann nicht gelöscht werden: Es existieren noch verknüpfte ' \
                            'Einträge (z.B. Spielberichte oder Dokumente).' },
             status: :unprocessable_entity
    end

    def incorrect_assignments
      return forbidden_response unless can_edit_full?

      season_id = params[:season_id] || Setting.current_season_id
      games = Referee.incorrect_assignments(season_id: season_id)

      render json: games.map { |g| game_summary(g, include_refs: true) }
    end

    private

    # Ein Datensatz je Aufruf, Fehler eingefangen: Ohne dieses rescue nimmt eine
    # Ausnahme bei Datensatz 41 (etwa RecordNotUnique, wenn parallel jemand dasselbe
    # Konto anlegt) den gesamten Report mit. Die 40 Konten davor sind dann angelegt
    # und ihre Mails unterwegs, der Admin sieht aber nur „Die Konten konnten nicht
    # angelegt werden" und hat keine Liste, wer schon ein Konto hat.
    def create_account_for(referee, created, failed)
      identity = { id: referee.id, lizenznummer: referee.lizenznummer,
                   name: "#{referee.vorname} #{referee.nachname}" }
      result = RefereeAccountCreator.new(referee, deliver_later: true).call

      if result.success?
        # email_sent mitgeben wie bei der Einzelanlage: Ein Konto, dessen
        # Willkommensmail nicht rausging, ist ohne diese Angabe nicht mehr
        # auffindbar — der Schiedsrichter kennt sein Initialpasswort nicht, und der
        # Datensatz fällt aus der Kandidatenliste heraus.
        created << identity.merge(email: referee.email, user_name: result.user.user_name,
                                  duplicate_email: result.duplicate_email,
                                  email_sent: result.email_sent)
      else
        failed << identity.merge(error: result.error)
      end
    rescue StandardError => e
      Rails.logger.error("create_missing_users: Referee #{referee.id} fehlgeschlagen: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      failed << identity.merge(error: "#{e.class}: #{e.message}")
    end

    # Standard ist „alles außer Karriere beendet". Seit dem Nachimport der
    # Beendeten (rund 4.250 Datensätze) wäre die Liste sonst zur Hälfte Historie.
    #
    # Datensätze ohne Ablaufdatum bleiben hier sichtbar (not_career_ended statt
    # in_career_window): Ein frisch angelegter Schiedsrichter hat noch keine
    # Gültigkeit und wäre sonst unmittelbar nach dem Anlegen unauffindbar. Die
    # Vereins- und die öffentliche Sicht verlangen dagegen einen Lizenznachweis.
    #
    # Zwei bewusste Ausnahmen:
    #   - Wer eine Lizenznummer eingibt, sucht gezielt und muss den Beendeten
    #     finden. Ohne diesen Durchstich wäre die Prüfung einer alten Nummer
    #     genau dann blind, wenn sie gebraucht wird — der Zweck des Nachimports.
    #   - `active=true` bleibt als Alt-Parameter erhalten, solange das Frontend
    #     ihn noch schickt.
    def apply_license_status_filter(referees)
      return referees.active if params[:active] == 'true'

      case params[:status]
      when 'alle' then referees
      when 'aktiv' then referees.active
      when 'abgelaufen' then referees.lapsed
      when 'beendet' then referees.career_ended
      when 'ohne_nachweis' then referees.without_license_proof
      else license_number_query? ? referees : referees.not_career_ended
      end
    end

    # Ein unbekannter Wert fiele sonst in den Standardzweig: Wer nach „beendet"
    # filtert und sich vertippt, bekäme eine Liste ganz ohne Beendete und
    # schlösse daraus, der Nachimport sei nicht gelaufen.
    KNOWN_STATUS_FILTERS = %w[alle aktiv abgelaufen beendet ohne_nachweis].freeze

    def valid_status_filter?
      params[:status].blank? || KNOWN_STATUS_FILTERS.include?(params[:status])
    end

    def license_number_query?
      params[:q].to_s.strip.match?(/\A\d+\z/)
    end

    def career_end_cutoff
      @career_end_cutoff ||= Referee.career_end_cutoff
    end

    def set_referee
      @referee = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type,
                                  referee_taggings: :referee_tag)
                        .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found
    end

    def referee_params
      params.require(:referee).permit(
        :lizenznummer, :vorname, :nachname, :geburtsdatum, :email,
        :club_id, :game_operation_id,
        :lizenzstufe, :gueltigkeit,
        :strasse, :hausnummer, :plz, :ort, :partner_lizenznummer, :guest
      )
    end

    def restricted_referee_params
      params.require(:referee).permit(
        :vorname, :nachname, :geburtsdatum, :email,
        :strasse, :hausnummer, :plz, :ort, :partner_lizenznummer, :guest
      )
    end

    def safe_referee_params
      can_edit_full? ? referee_params : restricted_referee_params
    end

    def sync_qualifications(referee)
      return unless params[:referee][:qualifications]

      incoming = Array(params[:referee][:qualifications]).filter_map do |q|
        type_id = q[:qualification_type_id].to_i
        next unless type_id.positive?

        valid_until = q[:valid_until].presence ? Date.strptime(q[:valid_until], '%d.%m.%Y') : nil
        { qualification_type_id: type_id, valid_until: valid_until }
      rescue Date::Error
        nil
      end

      ActiveRecord::Base.transaction do
        referee.referee_qualifications.destroy_all
        incoming.each do |attrs|
          referee.referee_qualifications.create!(
            referee_qualification_type_id: attrs[:qualification_type_id],
            valid_until: attrs[:valid_until]
          )
        end
      end
    end

    # Setzt die Tag-Zuordnungen eines Schiris neu (nur die Tags, die der Nutzer
    # auch sehen/verwalten darf – ein LV-Ansetzer kann keine fremden Verbands-Tags
    # zuweisen). Wird nur aufgerufen, wenn `tag_ids` mitgeschickt wurde.
    def sync_tags(referee)
      return unless params[:referee].key?(:tag_ids)

      ids = Array(params[:referee][:tag_ids]).map(&:to_i).select(&:positive?).uniq
      allowed = assignable_tag_ids
      ids &= allowed unless allowed.nil?
      referee.referee_tag_ids = ids
    end

    def can_manage_tags?
      ph = current_user.permission_hash
      ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?
    end

    # IDs der zuweisbaren Tags; nil = alle erlaubt (nur Admin bzw. ein explizit
    # auf Spielbetrieb 0 gesetzter Nutzer). Ein verbandsgebundener Nutzer – auch
    # FD – darf nur die eigenen Verbands-Tags plus globale Tags zuweisen.
    def assignable_tag_ids
      return nil if current_user.permission_hash[:admin].present?

      go_ids = tag_scope_go_ids
      return nil if go_ids.empty?

      RefereeTag.for_game_operations(go_ids).pluck(:id)
    end

    def authorize_referee_access!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present?
      return if ph[:ansetzer].present?
      return if ph[:vm].present?

      forbidden_response
    end

    def forbidden_response
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # include_vm: false schließt den VM-Zweig aus – VM darf die Schiris seines
    # Vereins nur lesen (show/games/club_stats), nicht bearbeiten/mergen
    # (update/merge übergeben false).
    def can_access_referee?(referee, include_vm: true)
      ph = current_user.permission_hash
      return true if ph[:admin].present?
      return true if ph[:rsk].present? && ph[:rsk].include?(0)
      return true if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

      # Rollen additiv: eine nicht passende RSK-/Ansetzer-Rolle darf den
      # VM-Zugriff auf die Schiris des eigenen Vereins nicht verdecken.
      if ph[:rsk].present? || ph[:ansetzer].present?
        go_ids = referee_scope_go_ids(ph)
        return true if lv_club_ids(go_ids).include?(referee.club_id) || go_ids.include?(referee.game_operation_id)
      end

      include_vm && ph[:vm].present? && ph[:vm].include?(referee.club_id)
    end

    # Neue Schiedsrichter anlegen darf nur, wer Vollzugriff hat (Admin oder
    # FD-RSK). Ein LV-RSK verwaltet nur bestehende Schiris (siehe can_edit_full?).
    def can_create_referee?
      can_edit_full?
    end

    # Ein Benutzerkonto für einen *bestehenden* Schiri anzulegen ist vom Anlegen
    # des Schiris getrennt und bleibt daher auch dem LV-RSK erlaubt (nicht nur
    # FD/Admin). Der Zugriff auf den konkreten Schiri wird zusätzlich über
    # can_access_referee? geprüft.
    def can_create_referee_login?
      ph = current_user.permission_hash
      ph[:admin].present? || ph[:rsk].present?
    end

    # E-Mail-Import und Massenanlage von Konten greifen in einem Zug über alle
    # Verbände hinweg — auch über die, für die der aufrufende Nutzer nicht
    # zuständig ist. Deshalb Admin-only, anders als die Einzelanlage
    # (can_create_referee_login?, dort schützt can_access_referee? den Zugriff).
    def can_manage_account_tools?
      current_user.permission_hash[:admin].present?
    end

    # Schiri-Feedback ist nur für Admin sowie die FD-Rollen (global gescopt, d. h.
    # rsk/ansetzer enthalten 0) sichtbar – nicht für LV-RSK, SBK oder VM.
    def can_view_feedback?
      ph = current_user.permission_hash
      ph[:admin].present? ||
        (ph[:rsk].present? && ph[:rsk].include?(0)) ||
        (ph[:ansetzer].present? && ph[:ansetzer].include?(0))
    end

    def average_rating(feedbacks, attribute)
      return nil if feedbacks.empty?

      (feedbacks.sum(&attribute).to_f / feedbacks.size).round(1)
    end

    def can_edit_full?
      ph = current_user.permission_hash
      ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    end

    # Kontaktdaten (E-Mail) in der Schiri-Liste. Deckt sich mit
    # menu_item_referee_admin: Admin, RSK und Ansetzer verwalten Schiris und
    # sehen die E-Mail ohnehin in der Detailansicht. Ein reiner Vereinsmanager
    # bekommt die Liste zwar (eigene Vereinsschiris), aber ohne Adressen.
    def can_view_contact_data?
      ph = current_user.permission_hash
      ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?
    end

    def restricted_user?
      !can_edit_full?
    end

    # Returns the single go_id for an LV-RSK user (used to auto-assign on create)
    def assigned_game_operation_id
      ph = current_user.permission_hash
      ph[:rsk]&.reject { |id| id.zero? }&.first
    end

    # Anzahl der Spiele in der aktuellen Saison je Lizenznummer – in EINER Query
    # (Aggregation in Ruby), um N+1-Count-Queries über die gesamte Schiri-Liste zu
    # vermeiden. Zählung analog zu Referee#games: kanonisch über die Referee-PK in
    # officiating_referee_ids (Fundament #45), plus Übergangs-Fallback über
    # referee_ids (Live-Erfassung) ODER den Lizenznummer-Präfix in referee1/2_string
    # (Freitext/Altdaten). PK-Treffer werden per pk_to_license auf denselben
    # Zähl-Schlüssel (Lizenznummer) abgebildet; pro Spiel/Schiri genau einmal.
    def season_game_counts(referees)
      season_id = Setting.current_season_id
      return {} if season_id.blank?

      liz = referees.filter_map(&:lizenznummer)
      return {} if liz.empty?

      lookup = liz.to_set
      pk_to_license = referees.each_with_object({}) { |r, h| h[r.id] = r.lizenznummer if r.lizenznummer }
      counts = Hash.new(0)

      Game.joins(game_day: :league)
          .where(leagues: { season_id: season_id })
          .pluck(:officiating_referee_ids, :referee_ids, :referee1_string, :referee2_string)
          .each do |officiating_ids, ids, str1, str2|
            matched = []
            Array(officiating_ids).each do |pk|
              license = pk_to_license[pk]
              matched << license if license
            end
            Array(ids).each { |l| matched << l if lookup.include?(l) }
            [str1, str2].each do |str|
              prefix = str.to_s[/\A\d+/]
              next unless prefix

              lz = prefix.to_i
              matched << lz if lookup.include?(lz)
            end
            matched.uniq.each { |l| counts[l] += 1 }
          end

      counts
    end

    def referee_json(referee, full: false, season_game_count: nil, contact: false)
      data = {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        lizenznummer_display: referee.lizenznummer_display,
        guest: referee.guest,
        vorname: referee.vorname,
        nachname: referee.nachname,
        club_id: referee.club_id,
        club_name: referee.club&.name,
        landesverband: referee.landesverband,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        active: !referee.guest? && referee.gueltigkeit.present? && referee.gueltigkeit >= Date.current,
        # active | lapsed | career_ended | unknown – trägt Badge und Status-Filter
        # der Liste. Der Stichtag wird je Request einmal berechnet, nicht je Zeile.
        license_status: referee.license_status(career_end_cutoff),
        tags: referee_tags_for(referee).map { |t| tag_summary(t) },
        tag_ids: referee_tags_for(referee).map(&:id)
      }

      data[:season_game_count] = season_game_count unless season_game_count.nil?
      # Konto-Badge der Liste. Gleiche Grenze wie die Kontaktdaten: Wer die
      # Adressen der Schiris verwaltet, soll sehen, wer sich damit anmelden kann.
      # Bewusst nur hier und nicht auch unter `full`: Die Detailansicht liefert mit
      # user_id/user_name schon mehr, und `full` ist nicht an die Kontaktdaten
      # gebunden — ein Vereinsmanager erreicht sie für die Schiris seines Vereins.
      data[:has_user] = referee.user.present? if contact
      # Die Detailansicht liefert die E-Mail wie bisher immer mit; in der Liste
      # nur für Rollen mit Zugriff auf Kontaktdaten (siehe can_view_contact_data?).
      data[:email] = referee.email if contact || full

      if full
        data.merge!(
          geburtsdatum: referee.geburtsdatum&.strftime('%d.%m.%Y'),
          game_operation_id: referee.game_operation_id,
          strasse: referee.strasse,
          hausnummer: referee.hausnummer,
          plz: referee.plz,
          ort: referee.ort,
          partner_lizenznummer: referee.partner_lizenznummer,
          qualifications: referee.referee_qualifications.map { |q| qualification_json(q) },
          user_id: referee.user&.id,
          user_name: referee.user&.user_name
        )
      end

      data
    end

    def feedback_json(feedback)
      game = feedback.game
      {
        id: feedback.id,
        game_id: feedback.game_id,
        game_number: game&.game_number,
        date: game&.game_day&.date,
        league: game&.league&.name,
        team_name: feedback.team&.name,
        referee_names: feedback.referee_names,
        line_rating: feedback.line_rating,
        line_comment: feedback.line_comment,
        communication_rating: feedback.communication_rating,
        communication_comment: feedback.communication_comment,
        general_comment: feedback.general_comment,
        status: feedback.status,
        # Abgabeweg (Konto oder Einmal-Link), bewusst ohne Namen oder Adresse der
        # abgebenden Person: Für die Einordnung einer Rückmeldung genügt der Weg,
        # verantwortlich ist ohnehin die genannte Mannschaft.
        submitted_via: feedback.submitted_via,
        created_at: feedback.created_at.iso8601
      }
    end

    # Tags aus den (per includes vorgeladenen) Taggings ableiten, damit die Liste
    # keine N+1-Query je Schiri auslöst.
    def referee_tags_for(referee)
      referee.referee_taggings.map(&:referee_tag).compact.sort_by { |t| t.name.to_s.downcase }
    end

    def tag_summary(tag)
      { id: tag.id, name: tag.name, color: tag.color }
    end

    def qualification_json(q)
      {
        id: q.id,
        qualification_type_id: q.referee_qualification_type_id,
        qualification_type_name: q.referee_qualification_type&.name,
        valid_until: q.valid_until&.strftime('%d.%m.%Y')
      }
    end

    def game_summary(game, include_refs: false)
      data = {
        id: game.id,
        game_number: game.game_number,
        date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        league: game.league&.name,
        season_id: game.game_day.league&.season_id,
        result: game.result_string
      }

      if include_refs
        data[:referee1] = game.referee1_string
        data[:referee2] = game.referee2_string
      end

      data
    end
  end
end
