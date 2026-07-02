module Admin
  class RefereesController < ApplicationController
    include RefereeScoping

    before_action :authorize_referee_access!
    before_action :set_referee,
                  only: %i[show update destroy games wallet_pass club_stats merge create_user destroy_user feedbacks]

    # GET /api/v2/admin/referees
    def index
      referees = Referee.includes(club: :state_association,
                                  referee_qualifications: :referee_qualification_type,
                                  referee_taggings: :referee_tag)

      referees = scope_to_permitted_referees(referees)

      referees = referees.search(params[:q]) if params[:q].present?
      referees = referees.by_landesverband(params[:landesverband]) if params[:landesverband].present?
      referees = referees.by_lizenzstufe(params[:lizenzstufe]) if params[:lizenzstufe].present?
      referees = referees.active if params[:active] == 'true'
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
      render json: referees.map { |r| referee_json(r, season_game_count: counts[r.lizenznummer].to_i) }
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
      return forbidden_response unless can_access_referee?(@referee)

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

      user = @referee.user
      user.destroy if user && user.id != current_user.id
      @referee.destroy
      head :no_content
    end

    # POST /api/v2/admin/referees/:id/merge
    def merge
      return forbidden_response unless can_access_referee?(@referee)

      secondary = Referee.find_by(id: params[:secondary_id])
      return render json: { message: 'Secondary-Schiedsrichter nicht gefunden.' }, status: :not_found unless secondary
      return forbidden_response unless can_access_referee?(secondary)

      secondary.merge_into!(@referee, current_user.id)
      render json: { message: 'Schiedsrichter erfolgreich zusammengeführt.', master_id: @referee.id }
    rescue ArgumentError => e
      render json: { message: e.message }, status: :unprocessable_entity
    end

    # POST /api/v2/admin/referees/:id/wallet_pass
    def wallet_pass
      return forbidden_response unless can_access_referee?(@referee)

      if @referee.guest?
        render json: { error: 'Gast-Schiedsrichter erhalten keinen Wallet-Ausweis' }, status: :unprocessable_entity
        return
      end

      pass_url = issue_wallet_pass(@referee)

      if pass_url.blank?
        render json: { error: 'Passmeister lieferte keine Pass-URL' }, status: :unprocessable_entity
        return
      end

      mail_sent = @referee.email.present?
      RefereeMailer.wallet_pass_issued(@referee, pass_url).deliver_later if mail_sent

      # mail_sent meldet dem Frontend, ob eine Benachrichtigung rausging. Ohne
      # hinterlegte E-Mail wird der Pass erstellt, aber keine Mail versendet –
      # das soll sichtbar zurückgemeldet und nicht still übersprungen werden.
      render json: { url: pass_url, mail_sent: mail_sent }
    rescue PassmeisterService::Error => e
      Rails.logger.warn("Admin::RefereesController#wallet_pass passmeister error for referee #{@referee&.id}: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Admin::RefereesController#wallet_pass failed for referee #{@referee&.id}: #{e.class}: #{e.message}")
      sentry_id = Sentry.capture_exception(e)
      render json: {
        error: 'Wallet-Pass konnte nicht erstellt werden. Bitte später erneut versuchen.',
        sentry_id: sentry_id
      }, status: :unprocessable_entity
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

      if @referee.user.present?
        return render json: { error: 'Diesem Schiedsrichter ist bereits ein Benutzerkonto zugeordnet.' },
                      status: :unprocessable_entity
      end

      duplicate_email = @referee.email.present? && User.exists?(email: @referee.email)

      user_name = @referee.lizenznummer.present? ? "sr-#{@referee.lizenznummer}" : "sr-g#{@referee.id}"

      user = User.new(
        user_name: user_name,
        first_name: @referee.vorname,
        last_name: @referee.nachname,
        email: @referee.email.presence,
        password: SecureRandom.hex(12),
        permissions: [{ 'user_group_id' => 6 }],
        referee_id: @referee.id
      )

      if user.save
        email_sent = false
        begin
          if user.email.present?
            user.send_referee_account_information
            email_sent = true
          end
        rescue StandardError => e
          Rails.logger.warn("create_user: Begrüßungs-Mail für User #{user.id} fehlgeschlagen: #{e.message}")
        end
        render json: referee_json(@referee.reload, full: true).merge(email_sent:, duplicate_email:)
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
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

    # Erzeugt/aktualisiert den Passmeister-Wallet-Pass und speichert die URL am Referee.
    # Gibt die Pass-URL zurück, oder nil falls Passmeister keine lieferte (geloggt).
    def issue_wallet_pass(referee)
      result = PassmeisterService.create_or_update_pass(referee)
      pass_url = result.dig('pass', 'walletSafe', 'urls', 'default')

      if pass_url.blank?
        Rails.logger.warn(
          "Passmeister: keine URL für Referee #{referee.id} (Lizenz #{referee.lizenznummer}). " \
          "Response-Top-Level-Keys: #{result.keys.inspect}, " \
          "walletSafe-Keys: #{result.dig('pass', 'walletSafe')&.keys.inspect}"
        )
        return nil
      end

      referee.update_columns(
        wallet_pass_issued_at: Time.current,
        wallet_pass_url: pass_url
      )
      pass_url
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

    def can_access_referee?(referee)
      ph = current_user.permission_hash
      return true if ph[:admin].present?
      return true if ph[:rsk].present? && ph[:rsk].include?(0)
      return true if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

      if ph[:rsk].present? || ph[:ansetzer].present?
        go_ids = referee_scope_go_ids(ph)
        lv_club_ids(go_ids).include?(referee.club_id) || go_ids.include?(referee.game_operation_id)
      elsif ph[:vm].present?
        ph[:vm].include?(referee.club_id)
      else
        false
      end
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
    # vermeiden. Zählung analog zu Referee#games: Treffer über referee_ids
    # (Live-Erfassung) ODER den Lizenznummer-Präfix in referee1/2_string
    # (Freitext/Altdaten); pro Spiel/Schiri genau einmal.
    def season_game_counts(referees)
      season_id = Setting.current_season_id
      return {} if season_id.blank?

      liz = referees.filter_map(&:lizenznummer)
      return {} if liz.empty?

      lookup = liz.to_set
      counts = Hash.new(0)

      Game.joins(game_day: :league)
          .where(leagues: { season_id: season_id })
          .pluck(:referee_ids, :referee1_string, :referee2_string)
          .each do |ids, str1, str2|
            matched = []
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

    def referee_json(referee, full: false, season_game_count: nil)
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
        active: !referee.guest? && referee.gueltigkeit.present? && referee.gueltigkeit >= Date.today,
        wallet_pass_issued_at: referee.wallet_pass_issued_at&.iso8601,
        wallet_pass_url: referee.wallet_pass_url,
        tags: referee_tags_for(referee).map { |t| tag_summary(t) },
        tag_ids: referee_tags_for(referee).map(&:id)
      }

      data[:season_game_count] = season_game_count unless season_game_count.nil?

      if full
        data.merge!(
          geburtsdatum: referee.geburtsdatum&.strftime('%d.%m.%Y'),
          email: referee.email,
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
