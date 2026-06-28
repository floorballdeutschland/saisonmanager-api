module Admin
  class RefereeAssignmentsController < ApplicationController
    include RefereeScoping

    before_action :authenticate_user
    before_action :authorize_assigner!

    # Sentinel, den der Spiel-Editor in Game#nominated_referee_string schreibt,
    # wenn die Ansetzung durch die RSK erfolgen soll.
    RSK_ASSIGNMENT_MARKER = 'Ansetzung durch RSK'.freeze

    # GET /api/v2/admin/referee_assignments
    def index
      scope = RefereeAssignment.includes(
        :referee1, :referee2, :coach, :club,
        game: { game_day: [:league, :arena, :club] }
      )

      # Serverseitiger LV-Scope: ein nicht-globaler Ansetzer sieht nur Ansetzungen
      # für Spiele in seinem game_operation-Scope (analog zu #games).
      go_ids = assigner_scope_go_ids
      if go_ids
        scoped_game_ids = Game.joins(game_day: :league)
                              .where(leagues: { game_operation_id: go_ids })
                              .select(:id)
        scope = scope.where(game_id: scoped_game_ids)
      end

      if params[:game_operation_id].present?
        scope = scope.joins(game: { game_day: :league })
                     .where(leagues: { game_operation_id: params[:game_operation_id] })
      end

      if params[:season_id].present?
        scope = scope.joins(game: { game_day: :league })
                     .where(leagues: { season_id: params[:season_id] })
      end

      if params[:date_from].present?
        scope = scope.joins(game: :game_day)
                     .where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end

      if params[:date_to].present?
        scope = scope.joins(game: :game_day)
                     .where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      render json: scope.map { |a| assignment_json(a) }
    end

    # GET /api/v2/admin/referee_assignments/games?season_id=X&date_from=Y&date_to=Z
    def games
      go_ids = assigner_scope_go_ids

      scope = Game.not_started.includes(
        :home_team, :guest_team, :referee_assignment,
        game_day: [{ league: :game_operation }, :arena, :club]
      ).joins(game_day: :league)

      scope = scope.where(leagues: { game_operation_id: go_ids }) if go_ids

      scope = scope.where(leagues: { season_id: params[:season_id] }) if params[:season_id].present?

      if params[:date_from].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end
      if params[:date_to].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      # Nur Spiele, die für die RSK-Ansetzung markiert sind (Sentinel im
      # nominated_referee_string) oder für die bereits eine Ansetzung existiert.
      # Letzteres ist nötig, weil der Sentinel beim Veröffentlichen durch die
      # Schiedsrichter-Namen überschrieben wird – das Spiel soll dennoch sichtbar bleiben.
      scope = scope.where(
        'games.nominated_referee_string = ? OR games.id IN (?)',
        RSK_ASSIGNMENT_MARKER,
        RefereeAssignment.where.not(game_id: nil).select(:game_id)
      )

      scope = scope.order("game_days.date ASC, games.start_time ASC NULLS LAST")

      render json: scope.map { |g|
        a = g.referee_assignment
        go = g.game_day.league&.game_operation
        {
          id: g.id,
          game_number: g.game_number,
          date: g.game_day.date,
          start_time: g.start_time,
          home_team: g.home_team&.name,
          guest_team: g.guest_team&.name,
          # Vereins-IDs der beiden Mannschaften → clientseitige Befangenheits-Warnung,
          # wenn ein angesetzter Schiri/Coach Mitglied eines dieser Vereine ist.
          home_team_club_id: g.home_team&.club_id,
          guest_team_club_id: g.guest_team&.club_id,
          league: g.game_day.league&.name,
          # Bundesspielbetrieb (Spielbetrieb ohne Landesverband) → für die
          # clientseitige Lizenz-Vorauswahl (FD-Spiele defaulten auf N-Lizenz).
          national: go.present? && go.state_association_id.nil?,
          arena: g.game_day.arena&.name,
          arena_postcode: g.game_day.arena&.postcode,
          arena_city: g.game_day.arena&.city,
          club: g.game_day.club&.name,
          assignment_id: a&.id,
          assignment_status: a&.status
        }
      }
    end

    # GET /api/v2/admin/referee_assignments/clubs
    # Vereine, die als „angesetzter Verein" gewählt werden können: die Vereine
    # des eigenen Landesverbands (bzw. der via Freigabe geteilten LV), analog
    # zum Schiri-Bestands-Scope. Admins (kein Scope) erhalten alle Vereine.
    def clubs
      go_ids = assigner_scope_go_ids
      scope = go_ids ? Club.where(id: lv_club_ids(go_ids)) : Club.all
      render json: scope.order(:name).map { |c| { id: c.id, name: c.name } }
    end

    # GET /api/v2/admin/referee_assignments/available?date=YYYY-MM-DD&game_id=X
    def available
      date = Date.parse(params[:date]) rescue nil
      return render json: { error: 'Ungültiges Datum' }, status: :bad_request unless date

      game = Game.find_by(id: params[:game_id])
      is_cup = game&.league&.league_category_id.to_s.in?(%w[3 4])

      # Nur Schiris, die für den Tag aktiv ihre Verfügbarkeit hinterlegt haben,
      # kommen für eine Ansetzung infrage.
      available_ids = RefereeAvailability.where(date: date).pluck(:referee_id)

      if is_cup
        # For cup games, only same-day conflicts are ignored
        assigned_ids = []
      else
        assigned_ids = RefereeAssignment
          .where(status: %w[tentative published])
          .joins(game: :game_day)
          .where("TO_DATE(game_days.date, 'YYYY-MM-DD') = ?", date)
          .pluck(:referee1_id, :referee2_id)
          .flatten
          .compact
      end

      # Verbands-Scope wie in der Verfügbarkeits-Matrix: ein LV-Ansetzer sieht nur
      # Schiris seines Verbands (inkl. via Freigabe zugeordneter Vereine), ein
      # globaler/FD-Ansetzer alle. Die Lizenz-Vorauswahl passiert clientseitig.
      # Verfügbar = hat für den Tag eine Verfügbarkeit hinterlegt und ist nicht
      # bereits tagesgleich angesetzt.
      referees = scope_to_permitted_referees(
        Referee.where(guest: false).where(id: available_ids).where.not(id: assigned_ids)
      ).order(:nachname, :vorname)

      render json: referees.map { |r|
        {
          id: r.id,
          lizenznummer: r.lizenznummer,
          lizenznummer_display: r.lizenznummer_display,
          vorname: r.vorname,
          nachname: r.nachname,
          lizenzstufe: r.lizenzstufe,
          kurzfristig_mobil: r.kurzfristig_mobil,
          partner_lizenznummer: r.partner_lizenznummer,
          club_id: r.club_id
        }
      }
    end

    # GET /api/v2/admin/referee_assignments/available_coaches?date=YYYY-MM-DD
    # Mögliche Schiedsrichtercoaches: Schiedsrichter mit gültiger Beobachtungs-
    # Zusatzlizenz (Qualifikationstyp „B…") und hinterlegter Verfügbarkeit am Spieltag.
    def available_coaches
      date = Date.parse(params[:date]) rescue nil
      return render json: { error: 'Ungültiges Datum' }, status: :bad_request unless date

      available_ids = RefereeAvailability.where(date: date).pluck(:referee_id)

      referees = Referee.where(guest: false)
                        .where(id: available_ids)
                        .joins(referee_qualifications: :referee_qualification_type)
                        .where('referee_qualification_types.name LIKE ?', 'B%')
                        .where('referee_qualifications.valid_until IS NULL OR referee_qualifications.valid_until >= ?', date)
                        .distinct
                        .order(:nachname, :vorname)

      render json: referees.map { |r|
        {
          id: r.id,
          lizenznummer: r.lizenznummer,
          lizenznummer_display: r.lizenznummer_display,
          vorname: r.vorname,
          nachname: r.nachname,
          lizenzstufe: r.lizenzstufe,
          club_id: r.club_id
        }
      }
    end

    # POST /api/v2/admin/referee_assignments
    def create
      return unless authorize_game_scope!(Game.find_by(id: assignment_params[:game_id]))

      assignment = RefereeAssignment.new(assignment_params)
      assignment.created_by = current_user.id
      assignment.updated_by = current_user.id

      if assignment.save
        render json: assignment_json(assignment.reload), status: :created
      else
        render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_assignments/:id
    def update
      assignment = RefereeAssignment.find(params[:id])
      # Sowohl das bestehende als auch das Ziel-Spiel müssen im Scope liegen
      # (game_id ist über assignment_params änderbar).
      return unless authorize_game_scope!(assignment.game)

      target_game_id = assignment_params[:game_id]
      return if target_game_id.present? && !authorize_game_scope!(Game.find_by(id: target_game_id))

      assignment.updated_by = current_user.id

      # Besetzung vor dem Update merken, um bei veröffentlichten Ansetzungen eine
      # echte Änderung (Schiri-Menge oder Coach) zu erkennen.
      was_published = assignment.status == 'published'
      previous_lineup = assignment_lineup(assignment)
      previous_official_ids = assignment_official_ids(assignment)
      previous_public_string = assignment_public_string(assignment)

      if assignment.update(assignment_params)
        assignment.reload
        if was_published
          if assignment.club_assignment?
            # Vereins-Ansetzung: öffentlichen Spielplan auf den Vereinsnamen
            # setzen. Es geht keine Mail an den Verein – aber zuvor angesetzte
            # (und bereits benachrichtigte) Schiris/Coach müssen über ihre
            # Abberufung informiert werden.
            new_string = assignment_public_string(assignment)
            assignment.game.update!(nominated_referee_string: new_string.to_s) if new_string != previous_public_string
            notify_removed_officials(assignment, previous_official_ids, new_string)
          elsif assignment_lineup(assignment) != previous_lineup
            notify_published_lineup_change(assignment, previous_official_ids)
          end
        end
        render json: assignment_json(assignment)
      else
        render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # POST /api/v2/admin/referee_assignments/:id/notify
    def notify
      assignment = RefereeAssignment.find(params[:id])
      return unless authorize_game_scope!(assignment.game)
      date = Date.parse(assignment.game.game_day.date) rescue nil

      assignment.referees.each do |referee|
        next unless referee.email.present?
        RefereeMailer.tentative_assignment_notification(referee, date).deliver_later
      end

      assignment.update_column(:notified_tentative_at, Time.current)
      render json: assignment_json(assignment.reload)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # POST /api/v2/admin/referee_assignments/:id/publish
    def publish
      assignment = RefereeAssignment.find(params[:id])
      game = assignment.game
      raise ActiveRecord::RecordNotFound unless game

      return unless authorize_game_scope!(game)

      public_string = assignment_public_string(assignment)

      ActiveRecord::Base.transaction do
        assignment.update!(status: 'published', published_at: Time.current, updated_by: current_user.id)
        game.update!(nominated_referee_string: public_string) if public_string.present?
      end

      expires_at = 72.hours.from_now
      license_token = Rails.application.message_verifier('license_list').generate(
        { game_id: assignment.game_id, expires_at: expires_at.iso8601 },
        expires_in: 72.hours
      )
      frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
      license_list_url = "#{frontend_base}/lizenzliste?token=#{CGI.escape(license_token)}"

      coach = assignment.coach
      assignment.referees.each do |referee|
        next unless referee.email.present?
        partner = assignment.referees.find { |r| r.id != referee.id }
        RefereeMailer.published_assignment_notification(
          referee,
          game,
          partner,
          game.game_day.club&.contact_email,
          coach:,
          license_list_url:,
          license_expires_at: expires_at
        ).deliver_later
      end

      # Der Coach erhält dieselben Details/Lizenzlisten plus die Namen der Schiris
      # (bzw. bei einer Vereins-Ansetzung den Namen des angesetzten Vereins).
      if coach&.email.present?
        official_names = if assignment.club_assignment?
                           assignment.club&.name.to_s
                         else
                           assignment.referees.map { |r| "#{r.vorname} #{r.nachname}" }.join(', ')
                         end
        RefereeMailer.published_coach_notification(
          coach,
          game,
          official_names,
          game.game_day.club&.contact_email,
          license_list_url:,
          license_expires_at: expires_at
        ).deliver_later
      end

      notify_host_if_complete(game.game_day)

      render json: assignment_json(assignment.reload)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # GET /api/v2/admin/referee_assignments/availability?season_id=X&date_from=&date_to=
    # Wochenend-Verfügbarkeitsmatrix („war room") für alle aktiven Schiedsrichter
    # des eigenen Verbands: je Schiri × Spielwochenende ein Status
    # verfügbar (Verfügbarkeit hinterlegt) | nicht verfügbar | angesetzt (bereits eingeteilt).
    def availability
      go_ids = assigner_scope_go_ids

      gd_scope = GameDay.joins(:league, :games)
      gd_scope = gd_scope.where(leagues: { game_operation_id: go_ids }) if go_ids
      gd_scope = gd_scope.where(leagues: { season_id: params[:season_id] }) if params[:season_id].present?
      if params[:date_from].present?
        gd_scope = gd_scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end
      if params[:date_to].present?
        gd_scope = gd_scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      # Spielanzahl je Datum (string 'YYYY-MM-DD').
      games_per_date = gd_scope.group('game_days.date').count
      game_dates = games_per_date.keys.compact

      # Wochenenden (Sa) aus den Spieldaten ableiten.
      weekends = {} # sat_str => { dates: Array, game_count: Integer }
      game_dates.each do |date_str|
        d = Date.parse(date_str) rescue next
        sat = weekend_saturday(d)
        bucket = (weekends[sat.to_s] ||= { dates: [], game_count: 0 })
        bucket[:dates] << date_str
        bucket[:game_count] += games_per_date[date_str]
      end

      # Verfügbarkeiten und Ansetzungen nur für die relevanten Spieldaten vorladen.
      date_objs = game_dates.filter_map { |s| Date.parse(s) rescue nil }
      available = Hash.new { |h, k| h[k] = [] }
      RefereeAvailability.where(date: date_objs).pluck(:referee_id, :date).each do |rid, d|
        available[rid] << d.to_s
      end

      assigned = Hash.new { |h, k| h[k] = [] }
      RefereeAssignment.where(status: %w[tentative published])
                       .joins(game: :game_day)
                       .where(game_days: { date: game_dates })
                       .pluck(:referee1_id, :referee2_id, 'game_days.date')
                       .each do |r1, r2, date_str|
        assigned[r1] << date_str if r1
        assigned[r2] << date_str if r2
      end

      # Schiri-Bestand identisch zum Schiri-Admin: globale Rolle (inkl. Bundes-
      # Spielbetrieb FD) sieht alle Referees, sonst die des eigenen LV. Bewusst
      # über scope_to_permitted_referees statt go_ids – referees.game_operation_id
      # ist oft leer, die Verbandszuordnung läuft v. a. über den Verein.
      referees = scope_to_permitted_referees(Referee.active.where(guest: false))
                 .order(:nachname, :vorname)

      sorted_keys = weekends.keys.sort
      render json: {
        weekends: sorted_keys.map do |sat|
          {
            key: sat,
            saturday: sat,
            sunday: (Date.parse(sat) + 1).to_s,
            game_count: weekends[sat][:game_count]
          }
        end,
        referees: referees.map do |r|
          available_dates = available[r.id]
          assigned_dates = assigned[r.id]
          states = {}
          sorted_keys.each do |sat|
            wdates = weekends[sat][:dates]
            states[sat] = if wdates.any? { |d| assigned_dates.include?(d) }
                            'assigned'
                          elsif wdates.any? { |d| available_dates.include?(d) }
                            'available'
                          else
                            'unavailable'
                          end
          end
          {
            id: r.id,
            lizenznummer_display: r.lizenznummer_display,
            vorname: r.vorname,
            nachname: r.nachname,
            lizenzstufe: r.lizenzstufe,
            states:
          }
        end
      }
    end

    private

    # Samstag des Spielwochenendes für ein Datum: So → Vortag (Sa),
    # Sa → selbst, Mo–Fr → kommender Sa (Fr-Spiele zählen zum folgenden Wochenende).
    def weekend_saturday(date)
      case date.wday
      when 0 then date - 1
      when 6 then date
      else date + (6 - date.wday)
      end
    end

    # Genau eine zusammenfassende Mail an den Ausrichter, sobald *alle* Spiele
    # des Spieltags eine veröffentlichte Ansetzung haben. host_notified_at
    # verhindert Doppelversand bei erneutem/nachträglichem Veröffentlichen.
    def notify_host_if_complete(game_day)
      return if game_day.nil? || game_day.host_notified_at.present?
      return if game_day.club&.contact_email.blank?

      game_ids = game_day.games.pluck(:id)
      return if game_ids.empty?
      return unless RefereeAssignment.published.where(game_id: game_ids).count == game_ids.size

      GameDayMailer.published_referees_to_host(game_day).deliver_later
      game_day.update_column(:host_notified_at, Time.current)
    end

    # Vergleichsstruktur der Besetzung: Schiris als Menge (Positionstausch
    # Schiri 1 ↔ 2 ist keine echte Änderung), Coach separat.
    def assignment_lineup(assignment)
      {
        referees: [assignment.referee1_id, assignment.referee2_id].compact.sort,
        coach: assignment.coach_id
      }
    end

    def assignment_official_ids(assignment)
      [assignment.referee1_id, assignment.referee2_id, assignment.coach_id].compact
    end

    # Zuvor angesetzte (und bereits benachrichtigte) Schiris/Coach, die durch die
    # neue Besetzung nicht mehr angesetzt sind – etwa beim Wechsel einer
    # veröffentlichten Ansetzung auf einen Verein – über die Änderung informieren.
    def notify_removed_officials(assignment, previous_official_ids, new_official_names)
      removed_ids = previous_official_ids - assignment_official_ids(assignment)
      return if removed_ids.empty?

      game = assignment.game
      Referee.where(id: removed_ids).each do |referee|
        next if referee.email.blank?

        RefereeMailer.updated_assignment_notification(referee, game, new_official_names.to_s, nil).deliver_later
      end
    end

    # Eine veröffentlichte Ansetzung wurde umbesetzt: öffentlichen Spielplan
    # (nominated_referee_string) aktualisieren und je *eine* Update-Mail an die
    # alten und neuen Schiris/den Coach sowie an den Ausrichter senden.
    def notify_published_lineup_change(assignment, previous_official_ids)
      game = assignment.game

      parts = assignment.referees.map do |r|
        [r.lizenznummer_display.presence, "#{r.nachname}, #{r.vorname}"].compact.join(' ')
      end
      # Immer schreiben (auch leer): Werden alle Schiris entfernt, muss der
      # öffentliche Spielplan die alten Namen verlieren – nicht stehen lassen.
      game.update!(nominated_referee_string: parts.join(' / '))

      official_names = assignment.referees.map { |r| "#{r.vorname} #{r.nachname}" }.join(', ')
      coach = assignment.coach

      affected_ids = (previous_official_ids + assignment_official_ids(assignment)).uniq
      Referee.where(id: affected_ids).each do |referee|
        next if referee.email.blank?
        RefereeMailer.updated_assignment_notification(referee, game, official_names, coach).deliver_later
      end

      GameDayMailer.updated_referees_to_host(game).deliver_later if game.game_day.club&.contact_email.present?
    end

    def authorize_assigner!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:ansetzer].present?
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Fine-grained: Ein nicht-globaler Ansetzer darf nur Spiele in seinem
    # game_operation-Scope ansetzen/benachrichtigen/veröffentlichen.
    # Gibt false zurück und rendert 403, wenn das Spiel außerhalb des Scopes liegt.
    def authorize_game_scope!(game)
      unless game
        render json: { error: 'Spiel nicht gefunden' }, status: :not_found
        return false
      end

      go_ids = assigner_scope_go_ids
      return true if go_ids.nil? # Admin

      go_id = game.game_day&.league&.game_operation_id
      return true if go_id.present? && go_ids.include?(go_id)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
      false
    end

    # game_operation_ids, für die der aktuelle Nutzer ansetzen darf.
    # nil = unbeschränkt (Admin).
    #
    # Liest die game_operation_ids direkt aus den Roh-Permissions der Ansetzer-Rolle
    # (user_group_id == 7) statt aus permission_hash[:ansetzer]. Damit umgehen wir die
    # in User#permission_hash enthaltene Hochstufung einer Bundes-GO (FD, ohne
    # state_association_id) auf [0] = „alle Verbände" – sonst sähe der FD-Ansetzer auch
    # Spiele fremder Landesverbände (#351, 4.3). Jeder Ansetzer setzt nur für seine
    # eigene(n) game_operation_id(s) an.
    def assigner_scope_go_ids
      return nil if current_user.permission_hash[:admin].present?

      go_ids = current_user.permissions
                           .select { |p| p['user_group_id'].to_i == 7 }
                           .map { |p| p['game_operation_id'].to_i }
                           .uniq
      # Explizit global (0) oder einzeln auf *alle* Spielbetriebe berechtigt →
      # keine Einschränkung. Nur die permission_hash-Hochstufung einer einzelnen
      # Bundes-GO auf „alle Verbände" wird hier bewusst NICHT übernommen.
      return nil if go_ids.include?(0) || (GameOperation.pluck(:id) - go_ids).empty?

      go_ids
    end

    def assignment_params
      params.require(:assignment).permit(:game_id, :referee1_id, :referee2_id, :coach_id, :club_id, :status)
    end

    def assignment_json(a)
      {
        id: a.id,
        game_id: a.game_id,
        status: a.status,
        notified_tentative_at: a.notified_tentative_at&.iso8601,
        published_at: a.published_at&.iso8601,
        referee1: a.referee1 ? referee_stub(a.referee1) : nil,
        referee2: a.referee2 ? referee_stub(a.referee2) : nil,
        coach: a.coach ? referee_stub(a.coach) : nil,
        club: a.club ? { id: a.club.id, name: a.club.name } : nil,
        game: game_stub(a.game)
      }
    end

    # Öffentliche Schiedsrichter-Angabe im Spielplan (nominated_referee_string):
    # bei Vereins-Ansetzung der Vereinsname, sonst die Schiedsrichter-Namen.
    def assignment_public_string(assignment)
      if assignment.club_assignment?
        assignment.club&.name.to_s
      else
        assignment.referees.map do |r|
          [r.lizenznummer_display.presence, "#{r.nachname}, #{r.vorname}"].compact.join(' ')
        end.join(' / ')
      end
    end

    def referee_stub(r)
      {
        id: r.id,
        lizenznummer_display: r.lizenznummer_display,
        vorname: r.vorname,
        nachname: r.nachname,
        lizenzstufe: r.lizenzstufe,
        partner_lizenznummer: r.partner_lizenznummer,
        # Nur für die RSK in der Ansetzungs-Ansicht sichtbar (dringender Fall, #643).
        telefonnummer: r.telefonnummer
      }
    end

    def game_stub(g)
      return nil unless g
      {
        id: g.id,
        game_number: g.game_number,
        date: g.game_day.date,
        home_team: g.home_team&.name,
        guest_team: g.guest_team&.name,
        league: g.league&.name,
        league_category_id: g.league&.league_category_id,
        season_id: g.game_day.league&.season_id,
        arena: g.game_day.arena&.name,
        arena_postcode: g.game_day.arena&.postcode,
        arena_city: g.game_day.arena&.city,
        club: g.game_day.club&.name,
        result: g.result_string
      }
    end
  end
end
