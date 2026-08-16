class GamesController < ApplicationController
  include SecretaryTokenAuthenticatable
  include IcalRenderable

  SECRETARY_ACTIONS = %i[
    add_player_to_lineup remove_player add_coach remove_coach set_captain
    set_starting_player set_player_award
    add_event remove_event update_event
    set_referee set_game_status set_flag set_string
    set_checklist_answers
    show_hidden
  ].freeze

  # Rechte, die ein Spielsekretariats-Link für die Spiele der von ihm
  # abgedeckten Spieltage im Frontend sichtbar macht (dort werden Bedienelemente
  # über `permission` eingeblendet). Welche Spieltage das sind, entscheidet
  # GameDaySecretaryLink#covers_game_day? – seit der hallenweiten Ausgabe können
  # es mehrere sein, nämlich alle Ligen einer Halle an einem Tag.
  #
  # Bewusst eine feste, enge Liste statt der Rechte des Link-Erstellers: der
  # kann Admin oder SBK sein, und dann bekäme der Link ungewollt Kontrollrechte
  # über den Spielbericht hinaus. Genau diese Aktionen erlaubt SECRETARY_ACTIONS
  # dem Token ohnehin schon. Nicht enthalten: edit_game, check_game,
  # edit_referee_nomination.
  SECRETARY_PERMISSIONS = %i[pregame_edit_home pregame_edit_guest edit_game_report].freeze

  VETO_ACTIONS = %i[show_checklist_veto submit_checklist_veto].freeze

  skip_before_action :authenticate_user, only: %i[show calendar] + SECRETARY_ACTIONS + VETO_ACTIONS
  # `calendar` fehlt hier absichtlich: Kalender-Abos können keinen API-Key
  # mitschicken, Begründung an TeamsController#calendar.
  before_action :authenticate_public_request, only: %i[show] + VETO_ACTIONS
  before_action :authenticate_with_secretary_token_or_user, only: SECRETARY_ACTIONS
  # `show` bleibt öffentlich (API-Key oder Cookie) und darf deshalb NICHT in
  # SECRETARY_ACTIONS: dort würde ein Token erzwungen und der anonyme Zugriff auf
  # die Spielseite brechen. Der Link wird hier nur gesetzt, wenn er mitkommt –
  # `show` wertet @secretary_link seit je aus, es wurde nur nie gefüllt.
  before_action :set_secretary_link_if_present, only: %i[show]

  # Es gibt bewusst kein #index: Die frühere Action lieferte per Game.all die
  # komplette Spieltabelle, ohne Filter und ohne Grenze, öffentlich per
  # API-Key. Ersatz sind die gescopten Endpunkte leagues/:id/schedule,
  # leagues/:id/game_days/:game_day_number/schedule (die Spieltagsnummer
  # innerhalb der Liga, nicht die GameDay-ID) und teams/:id/matches.

  # GET /games/1
  def show
    game = Game.find(params[:id])

    delayed = delay_live_data?
    strip_delayed_events!(game)

    # full_hash parst bei jedem Aufruf die JSONB-Spalten (events, players, …)
    # und macht mehrere Folgequeries – für anonyme Abrufe (öffentliche
    # Spiel-Detailseite) cachen. updated_at im Key invalidiert bei jedem
    # Spiel-Event sofort; die delayed-Variante altert dadurch höchstens um die
    # TTL über die 10-Minuten-Verzögerung hinaus (unkritisch, Verzögerung ist
    # ein Mindestwert). Eingeloggte/Secretary-Abrufe variieren pro Nutzer und
    # bleiben ungecacht.
    hash =
      if current_user || @secretary_link
        game.full_hash
      else
        variant = delayed ? 'delayed' : 'realtime'
        Rails.cache.fetch("games/#{game.id}/full_hash/#{variant}/#{game.updated_at.to_f}",
                          expires_in: 1.minute) do
          game.full_hash
        end
      end
    # Vereinigung statt elsif-Kette: Wer angemeldet ist UND einen Link in der
    # Registerkarte hat, bekam bisher nur die Rechte seiner Rolle angezeigt, die
    # Schreibwege dahinter richteten sich aber allein nach dem Link (#428). Beide
    # Seiten rechnen jetzt additiv. Für anonyme Abrufe bleibt es bei nil, ein
    # leeres Array wäre im Frontend truthy.
    hash[:permission] = if current_user || @secretary_link
                          Array(current_user && game.user_permissions(current_user)) |
                            _secretary_permissions(game)
                        end
    hash.merge!(_checklist_hash(game)) if current_user || @secretary_link
    if current_user
      ph = current_user.permission_hash
      go_id = game.game_day.league.game_operation_id.to_i
      admin_or_sbk = ph[:admin].to_a.intersect?([0, go_id]) || ph[:sbk].to_a.intersect?([0, go_id])
      if admin_or_sbk
        hash[:record_updated_at] = game.record_updated_at
        hash[:record_updated_by_name] = User.find_by(id: game.record_updated_by)&.fullname
        hash[:post_submission_edited] = game.match_record_closed? &&
                                        game.match_record_closed_at.present? &&
                                        game.record_updated_at.present? &&
                                        game.record_updated_at > game.match_record_closed_at
      end
    end

    respond_to do |format|
      format.json { render json: hash }
      format.ics { render_ical([game]) }
    end
  end

  # GET /api/v2/calendar/games/1.ics — ohne API-Key, siehe
  # TeamsController#calendar.
  def calendar
    render_ical([Game.with_ical_associations.find(params[:id])])
  end

  # GET /games/scheduling_conflicts
  # Liefert Hallen-Belegungskonflikte für ein (geplantes) Spiel, ohne zu speichern.
  # Nicht-blockierend: das Frontend kann damit warnen, das Speichern bleibt erlaubt
  # (z. B. Turnierformate mit mehreren Feldern in einer Halle).
  def scheduling_conflicts
    game_day = GameDay.find_by(id: params[:game_day_id])
    return render json: { message: 'Spieltag nicht gefunden.' }, status: :not_found if game_day.nil?
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless game_scheduling_allowed?(game_day.league)

    conflicts = GameScheduleConflicts.new(
      game_day: game_day,
      start_time: params[:start_time],
      exclude_game_id: params[:game_id],
      duration_minutes: params[:duration_minutes]
    ).arena_conflicts

    render json: { conflicts: conflicts.map { |game| scheduling_conflict_hash(game) } }
  end

  # POST /games
  def create
    ph = current_user.permission_hash
    game = Game.new(game_create_update_params)
    game.correct_teams!
    game_operation_id = game.league.game_operation_id.to_i
    # Voreinstellung „Standardmäßig durch Ansetzer*in": neue Spiele gleich
    # markieren, damit die SBK das nicht je Spieltag anklicken muss. Nur, wenn
    # die Maske das Flag nicht ausdrücklich mitgeschickt hat.
    if game_create_update_params.key?(:person_level_assignment)
      game.person_level_assignment = false unless Game.person_level_assignment_allowed_for?(game.league)
    else
      game.person_level_assignment = Game.person_level_assignment_default_for?(game.league)
    end

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    game.created_by ||= current_user.id

    if allowed
      if game.save

        render json: { success: true }, status: :created
      else
        render json: { success: false, error: game.errors }, status: 400
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  # PATCH /games/1
  def update
    ph = current_user.permission_hash
    game = Game.find(params[:id])
    game.correct_teams!
    game_operation_id = game.league.game_operation_id.to_i

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    game.updated_by ||= current_user.id

    # Wie beim Anlegen: die Markierung darf nur stehen, wo die Personenebene
    # greift – sonst entsteht ein Spiel, das keine der beiden Ansichten
    # bearbeiten kann. Eine bereits gesetzte Markierung lässt sich weiterhin
    # entfernen, nur das Setzen ist gesperrt.
    update_attrs = game_create_update_params
    if update_attrs.key?(:person_level_assignment) &&
       !Game.person_level_assignment_allowed_for?(game.league)
      update_attrs = update_attrs.merge(person_level_assignment: false)
    end

    if allowed
      if game.update(update_attrs)
        # Änderungen an Anpfiff oder Absage (notice_type) benachrichtigen die
        # Beteiligten einer bereits veröffentlichten Ansetzung. Nur bei echter
        # Änderung dieser Felder (Dirty-Tracking): so lösen unbeteiligte Edits
        # und die Live-Erfassung (set_string/set_field, kein start_time) keine
        # Mail aus. Der Notifier prüft selbst, ob eine Ansetzung vorliegt.
        if game.saved_change_to_start_time? || game.saved_change_to_notice_type?
          GameChangeNotifier.notify(game)
        end

        render json: { success: true }
      else
        render json: { success: false, error: game.errors }, status: 400
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  # DELETE /games/1
  def destroy
    ph = current_user.permission_hash
    game = Game.find(params[:id])
    game_operation_id = game.league.game_operation_id.to_i

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    if game.deletable?
      if allowed
        if game.destroy
          render json: { success: true }
        else
          render json: { success: false, error: game.errors }, status: 400
        end
      else
        render json: { message: 'Keine Berechtigung.' }, status: :forbidden
      end
    else
      render json: { message: 'Spiel darf nicht gelöscht werden.' }, status: 400
    end
  end

  # Interne Spielbericht-Felder (Unterschriften, besondere Vorkommnisse etc.).
  # Nur für Rollen mit Bezug zum Spiel: Admin/SBK des Spielbetriebs sowie
  # VM/TM der beteiligten Mannschaften. Andere eingeloggte Nutzer erhalten ein
  # leeres Objekt statt 403, weil die Spiel-Detailseite den Endpoint für jeden
  # Login aufruft und der Frontend-ErrorInterceptor bei 403 hart umleitet.
  def show_hidden
    game = Game.find(params[:id])

    return render json: {} unless can_view_hidden_elements?(game)

    render json: game.hidden_elements
  end

  def editable
    game = Game.find(params[:id])
    allowed = game.can_edit_lineup?(current_user)

    render json: allowed
  end

  def users_games
    game_days = GameDay.past_games

    @games = game_days.map(&:games).flatten
  end

  # Verbandsweite Batch-Verarbeitung (Spiele automatisch starten/beenden) –
  # nur für Admins auslösbar.
  def update_start_end
    unless current_user.permission_hash[:admin].present?
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    Game.start_end_games
    render json: { success: true }
  end

  def add_player_to_lineup
    game = Game.find(params[:id])
    player = Player.find(params[:player_id]) if params[:player_id].present?

    allowed = can_edit_game?(game)

    if allowed
      # ensure we have the hash set
      game.players ||= {}

      side = params[:side]

      # ensure we have the hash set
      game.players[side] ||= []

      # check if we have a entry for that player
      if game.players[side].map { |p| p['player_id'] }.include?(params[:player_id].to_i)
        render json: { message: 'Spieler bereits vorhanden' }, status: :unprocessable_entity
      else
        item = {
          trikot_number: params[:trikot_number].to_i
        }

        item[:goalkeeper] = true if params[:goalkeeper].present?

        if params[:player_id].present?
          item[:player_id] = player.id
          item[:player_firstname] = player.first_name
          item[:player_name] = player.last_name
          item[:gender] = player.gender
          birthdate = player.birthdate
          item[:youth] = birthdate.present? && birthdate > 18.years.ago.to_date
        else
          item[:player_firstname] = params[:player_firstname]
          item[:player_name] = params[:player_name]
        end

        game.players[side] << item

        game.record_created_at ||= Time.now
        game.record_updated_at = Time.now
        game.record_created_by ||= author_user_id
        game.record_updated_by = author_user_id

        if game.save
          render json: { players: game.players[side], warning: lineup_license_warning(game, player, side) }
        else
          render json: { message: game.errors }, status: :unprocessable_entity
        end
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_starting_player
    game = Game.find(params[:id])
    player = Player.find(params[:player_id]) if params[:player_id].present?

    allowed = can_edit_game?(game)

    if allowed
      # Ensure we have the hash set
      game.starting_players ||= {}

      side = params[:side]
      position = params[:position]

      # Ensure we have the hash set for the side
      game.starting_players[side] ||= {
        goal: nil,
        defender1: nil,
        defender2: nil,
        center: nil,
        forward1: nil,
        forward2: nil
      }

      # Check if the position exists in the hash
      unless ['goal', 'defender1', 'defender2', 'center', 'forward1', 'forward2'].include?(position)
        render json: { message: 'Position existiert nicht' }, status: :unprocessable_entity
        return
      end

      # Add player to the position if player_id is present
      if params[:player_id].present? && player
        # Check if the player is already in starting_players

        if game.starting_players[side].values.include?(player.id)
          render json: { message: 'Spieler kann nur einmal im Startaufgebot vorkommen' }, status: :unprocessable_entity
          return
        else
          game.starting_players[side][position] = player.id
        end
      else
        game.starting_players[side][position] = nil
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.starting_players_with_numbers
      else
        render json: { message: game.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_player_award
    game = Game.find(params[:id])
    player = Player.find(params[:player_id]) if params[:player_id].present?

    allowed = can_edit_game?(game)

    if allowed
      # Ensure we have the hash set
      game.awards ||= {}

      side = params[:side]
      award = params[:award]

      # Ensure we have the hash set for the side
      game.awards[side] ||= {
        mvp: nil,
      }

      # Check if the position exists in the hash
      unless ['mvp'].include?(award)
        render json: { message: 'Auszeichnung konnte nicht gefunden werden' }, status: :unprocessable_entity
        return
      end

      # set award if player_id is present
      if params[:player_id].present? && player
        game.awards[side][award] = player.id
      else
        game.awards[side][award] = nil
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.awards_with_player_names
      else
        render json: { message: game.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def add_coach
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      side = params[:side]

      # Die JSONB-Spalten haben historisch den Default [] (Array). `||= {}`
      # greift dann nicht, weil [] truthy ist – ein anschließender
      # String-Key-Zugriff (coaches["coach1_string"] = …) würde auf einem Array
      # einen TypeError (500) werfen. Daher hart auf Hash normalisieren.
      game.home_team_coaches = {} unless game.home_team_coaches.is_a?(Hash)
      game.guest_team_coaches = {} unless game.guest_team_coaches.is_a?(Hash)

      last_name = params[:last_name].to_s.strip
      first_name = params[:first_name].to_s.strip

      full_name = [last_name, first_name].join ', '

      if side == 'home'
        prefix = "coach#{params[:number]}"
        game.home_team_coaches["#{prefix}_string"] = full_name
        game.home_team_coaches["#{prefix}_first_name"] = first_name
        game.home_team_coaches["#{prefix}_last_name"] = last_name
        key = "#{prefix}_signed"
        game.home_team_coaches[key] = true if params[key]
      else
        prefix = "coach#{params[:number]}"
        game.guest_team_coaches["#{prefix}_string"] = full_name
        game.guest_team_coaches["#{prefix}_first_name"] = first_name
        game.guest_team_coaches["#{prefix}_last_name"] = last_name
        key = "#{prefix}_signed"
        game.guest_team_coaches[key] = true if params[key]
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.players[side]
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_captain
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      # ensure we have the hash set
      game.players ||= {}

      side = params[:side]

      # ensure we have the hash set
      game.players[side] ||= []

      captain_set = false

      # check if we have a entry for that player

      game.players[side].map! do |p|
        p.except!('captain') if p['captain'].present?

        if p['trikot_number'].to_i == params[:trikot_number].to_i
          captain_set = true
          p['captain'] = true
        end

        p
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if captain_set && game.save
        render json: game.players[side]
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def remove_player
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      # ensure we have the hash set
      game.players ||= {}

      side = params[:side]

      # ensure we have the hash set
      game.players[side] ||= []

      game.players[side].reject! do |p|
        p['trikot_number'].to_i == params[:trikot_number]
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.players[side]
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def remove_coach
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      side = params[:side]

      # Siehe add_coach: [] (Array-Default) ist truthy, daher hart auf Hash
      # normalisieren, bevor wir per String-Key zugreifen.
      game.home_team_coaches = {} unless game.home_team_coaches.is_a?(Hash)
      game.guest_team_coaches = {} unless game.guest_team_coaches.is_a?(Hash)

      prefix = "coach#{params[:number]}"
      if side == 'home'
        game.home_team_coaches.reject! { |k, _v| k.starts_with?(prefix) }
      else
        game.guest_team_coaches.reject! { |k, _v| k.starts_with?(prefix) }
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.players[side]
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def add_event
    game = Game.find(params[:id])

    allowed = if !admin_or_scoped_sbk?(game) && game.match_record_closed?
                false
              else
                can_edit_game?(game)
              end

    if allowed
      if (error = event_input_error)
        return render json: { message: error }, status: :unprocessable_entity
      end

      # ensure we have the hash set
      game.events ||= []

      max_id = game.events.map { |e| e['id'] }.max || 0

      item = {
        id: max_id + 1,
        time: params[:time],
        period: params[:period],
        home_goals: params[:home_goals],
        guest_goals: params[:guest_goals],
        added_at: Time.current.to_i
      }.with_indifferent_access

      item[:home_number] = params[:home_number] if params[:home_number].present?
      item[:home_assist] = params[:home_assist] if params[:home_assist].present?
      item[:guest_number] = params[:guest_number] if params[:guest_number].present?
      item[:guest_assist] = params[:guest_assist] if params[:guest_assist].present?

      item[:event_type] = params[:event_type]
      item[:event_team] = params[:event_team]

      case params[:event_type]
      when 'penalty'
        item[:penalty_id] = params[:penalty_id]
        item[:penalty_code_id] = params[:penalty_code_id]
      when 'goal'
        item[:goal_type] = params[:goal_type] if params[:goal_type].present?
        item[:penalty_code_id] = params[:penalty_code_id] if params[:penalty_code_id].present?
        drop_penalty_shot_marker!(item)
      end

      # Straf-Labels einfrieren, damit der Spielbericht ohne Live-Lookup lesbar bleibt.
      Game.freeze_penalty_labels(item)

      game.events << item

      game.sort_events!

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.formatted_events
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def remove_event
    game = Game.find(params[:id])

    allowed = if !admin_or_scoped_sbk?(game) && game.match_record_closed?
                false
              else
                can_edit_game?(game)
              end

    if allowed
      # ensure we have the hash set
      game.events ||= []

      game.events.reject! do |p|
        p['id'].to_i == params[:event_id].to_i
      end

      game.sort_events!

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.save
        render json: game.formatted_events
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def update_event
    game = Game.find(params[:id])
    allowed = if !admin_or_scoped_sbk?(game) && game.match_record_closed?
                false
              else
                can_edit_game?(game)
              end

    if allowed
      game.events ||= []
      event = game.events.find { |e| e['id'].to_i == params[:event_id].to_i }
      return render json: { message: 'Ereignis nicht gefunden.' }, status: :not_found unless event

      if (error = event_input_error)
        return render json: { message: error }, status: :unprocessable_entity
      end

      event['time'] = params[:time]
      event['period'] = params[:period]
      event['home_goals'] = params[:home_goals]
      event['guest_goals'] = params[:guest_goals]
      event['event_type'] = params[:event_type]
      event['event_team'] = params[:event_team]

      if params[:event_team] == 'home'
        event['home_number'] = params[:home_number].presence
        event['home_assist'] = params[:home_assist].presence
        event.delete('guest_number')
        event.delete('guest_assist')
      else
        event['guest_number'] = params[:guest_number].presence
        event['guest_assist'] = params[:guest_assist].presence
        event.delete('home_number')
        event.delete('home_assist')
      end

      case params[:event_type]
      when 'penalty'
        event['penalty_id'] = params[:penalty_id]
        event['penalty_code_id'] = params[:penalty_code_id]
        event.delete('goal_type')
      when 'goal'
        event['goal_type'] = params[:goal_type].presence
        event['penalty_code_id'] = params[:penalty_code_id].presence
        event.delete('penalty_id')
        drop_penalty_shot_marker!(event)
      end

      # Straf-Labels neu einfrieren (bzw. bei Wechsel auf 'goal' entfernen).
      Game.freeze_penalty_labels(event)

      game.sort_events!
      game.record_updated_at = Time.now
      game.record_updated_by = author_user_id

      if game.save
        render json: game.formatted_events
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_flag
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      if params.dig(:game, :started).present? && params[:game][:started].to_s == 'true'
        home_present = game.players&.dig('home').present?
        guest_present = game.players&.dig('guest').present?
        unless home_present && guest_present
          return render json: { message: 'Aufstellung muss für beide Teams vorhanden sein.' }, status: :unprocessable_entity
        end

        unless game.referee1_present?
          return render json: {
            message: 'Es muss mindestens Schiedsrichter 1 eingetragen sein, bevor das Spiel gestartet werden kann.'
          }, status: :unprocessable_entity
        end
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id

      if game.update(game_flag_params)
        render json: game.events
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_string
    game = Game.find(params[:id])

    # Dieselbe Prüfung wie im übrigen Spielbericht: can_edit_game? entscheidet
    # zuerst über den Spielsekretariats-Link und fällt sonst auf
    # Game#can_edit_lineup? zurück. Blank so geprüft wird auch in
    # add_player_to_lineup, set_flag, set_referee, add_coach und set_captain.
    # add_event, remove_event und update_event legen zusätzlich eine Sperre für
    # abgeschlossene Berichte davor, set_game_status eine gegen das
    # Wiederöffnen. set_string hat wie set_flag keine solche Sperre: Wer den
    # Bericht bearbeiten darf, darf Zuschauerzahl oder Anwurfzeit auch nach dem
    # Abschluss noch berichtigen. Das war vorher schon so und ändert sich hier
    # nicht.
    #
    # Vorher stand hier eine eigene, nachgebaute Rechtekette über Admin,
    # gescopte SBK, VM der beteiligten Vereine und TM. Sie ließ zwei Fälle aus:
    #
    # 1. Den VM des **ausrichtenden** Vereins (game_day.club_id), den
    #    can_edit_lineup? kennt. Der fällt bei normalen Spieltagen nicht auf,
    #    weil der Ausrichter dort selbst mitspielt. Bei einem Turnier an einem
    #    Ort, etwa der DM, richtet ein Verein aber alle Partien aus und führt
    #    das Sekretariat. Dort konnte er Tore, Strafen, Kader und Betreuer
    #    erfassen, aber Spielsekretariat, Zeitnehmer, Livestream-Link,
    #    Zuschauerzahl, Anwurfzeit und Auszeiten nicht speichern: 403 auf jedem
    #    dieser Felder, und das Frontend warf ihn dabei aus dem laufenden
    #    Spielbericht.
    # 2. Den Sekretariats-Link in der Hand einer Person, die zugleich als Admin,
    #    SBK, VM oder TM angemeldet ist. Die lief in den Rollenzweig und nie in
    #    den Fallback. Der Link liegt eine Ebene höher in can_edit_game?, nicht
    #    in can_edit_lineup?.
    #
    # Die alte Kette ist damit eine Teilmenge dieser Prüfung. Der zuletzt noch
    # offene Ausnahmefall ist mit #428 erledigt: can_edit_game? entschied bei
    # gesetztem @secretary_link allein über den Link, wer angemeldet war und
    # zusätzlich einen gültigen, dieses Spiel aber nicht abdeckenden Token
    # mitschickte, wurde abgewiesen, obwohl seine Rolle gereicht hätte. Rolle und
    # Token zählen jetzt additiv.
    allowed = can_edit_game?(game)

    if allowed
      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= author_user_id
      game.record_updated_by = author_user_id
      if game.update(game_value_params)
        render json: game.events
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_referee
    game = Game.find(params[:id])

    allowed = can_edit_game?(game)

    if allowed
      ref_num = params[:referee_number].to_i
      license = (params[:license_id] || 0).to_i

      game.referee_ids ||= []
      game.referee_ids[ref_num - 1] = license

      # Kanonische, stabile Verknüpfung über die Referee-PK (die Lizenznummer ist
      # über den Schiri-Merge wanderbar). 0 = nicht auflösbar (Gast/Freitext).
      game.officiating_referee_ids ||= []
      game.officiating_referee_ids[ref_num - 1] =
        (license.positive? && Referee.where(lizenznummer: license).pick(:id)) || 0

      name = "#{license} #{params[:lastname]}, #{params[:firstname]}"

      if ref_num == 1
        game.referee1_string = name
      else
        game.referee2_string = name
      end

      game.record_updated_at = Time.now
      game.record_updated_by = author_user_id

      if game.save
        render json: game.referees
      else
        render json: { message: game.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def set_game_status
    game = Game.find(params[:id])

    ph = current_user&.permission_hash || {}
    sbk = admin_or_scoped_sbk?(game)
    allowed = can_edit_game?(game)

    if allowed
      if params[:game_status].present?
        old_status = game.game_status

        # VM/TM dürfen abgeschlossene Spielberichte nicht selbst wieder öffnen
        if !sbk && %w[match_record_closed finalized].include?(old_status)
          return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
        end

        # Die Spielberichtseingabe ("Events eintragen", Status ingame) darf erst
        # am Spieltag gestartet werden – nicht vorab. Späteres Nacherfassen (am
        # Spieltag oder danach) bleibt möglich. Admins dürfen für Korrekturen
        # übersteuern.
        if params[:game_status] == 'ingame' && old_status != 'ingame' && ph[:admin].blank?
          game_date = begin
            Date.parse(game.game_day.date)
          rescue ArgumentError, TypeError
            nil
          end
          if game_date && Time.zone.today < game_date
            message = "Die Spielberichtseingabe kann erst am Spieltag (#{game_date.strftime('%d.%m.%Y')}) gestartet werden."
            return render json: { message: message }, status: :unprocessable_entity
          end
        end

        if %w[match_record_closed finalized].include?(params[:game_status])
          referee_error = _missing_referee_error(game)
          return render json: { message: referee_error }, status: :unprocessable_entity if referee_error
        end

        if params[:game_status] == 'match_record_closed'
          checklist_error = _checklist_incomplete_error(game)
          return render json: { message: checklist_error }, status: :unprocessable_entity if checklist_error
        end

        game.game_status = params[:game_status]
        if %w[match_record_closed finalized].include?(params[:game_status]) && game.match_record_closed_at.nil?
          game.match_record_closed_at = Time.now
        end
        game.save

        if params[:game_status] == 'match_record_closed'
          _maybe_send_incident_report_reminder(game)
          _maybe_send_checklist_confirmation(game)
          _maybe_send_game_day_scan_reminder(game)
        end

        # Platzierungsspiele füllen, sobald ein Spiel einen abgeschlossenen
        # Status erreicht – auch direkt `finalized`. Sonst bliebe der K.-o.-Baum
        # leer, wenn das letzte Gruppenspiel direkt finalisiert wird (vgl. #515).
        if %w[match_record_closed finalized].include?(params[:game_status])
          Game.autofill_teams!(league_id: game.game_day.league_id)

          # TMs beider Mannschaften informieren und, falls hinterlegt, den
          # Feedback-Kontakt einladen (idempotent; No-Op ohne
          # referee_feedback_enabled). Greift hier nur, wenn der Bericht später
          # als 24 h nach dem Spiel geschlossen wird – im Regelfall ist das
          # Abgabefenster noch zu und der Cron-Lauf von
          # referee_feedback:notify_available verschickt die Mails später.
          #
          # Der Versand ist eine Nebenwirkung des Abschlusses, nicht Teil davon:
          # Der Bericht ist oben schon gespeichert, ein Fehler hier darf der
          # Spielleitung nicht als „Server-Fehler." gemeldet werden.
          begin
            RefereeFeedbackNotifier.new(game).notify
          rescue StandardError => e
            Rails.logger.error("RefereeFeedbackNotifier fehlgeschlagen (Spiel #{game.id}): #{e.class}: #{e.message}")
            Sentry.capture_exception(e) if defined?(Sentry)
          end
        end
      elsif params[:ingame_status].present?
        old_ingame_status = game.ingame_status
        game.ingame_status = params[:ingame_status]

        # TODO: check order
        game.save
      end

      render json: game
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def reopen_game
    game = Game.find(params[:id])
    unless admin_or_scoped_sbk?(game)
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    if %w[match_record_closed finalized].include?(game.game_status)
      if game.update(game_status: 'aftergame')
        render json: { success: true }
      else
        render json: { errors: game.errors.full_messages }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Spielbericht hat keinen abgeschlossenen Status.' }, status: :unprocessable_entity
    end
  end

  def set_checklist_answers
    game = Game.find(params[:id])
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_edit_game?(game)

    answers = params.require(:answers).map { |a| a.permit(:item_id, :question, :answer).to_h }
    unless answers.is_a?(Array) && answers.all? { |a| a.key?('item_id') && [true, false].include?(a['answer']) }
      return render json: { message: 'Ungültiges Format.' }, status: :unprocessable_entity
    end

    game.update!(checklist_answers: answers)
    render json: { success: true }
  end

  def _missing_referee_error(game)
    return nil if game.referee1_present?

    'Es muss mindestens Schiedsrichter 1 eingetragen sein, bevor der Spielbericht abgeschlossen werden kann.'
  end

  def _checklist_incomplete_error(game)
    sa = game.state_association
    return nil unless sa&.checklist_items&.any?

    required_ids = sa.checklist_items.pluck(:id).sort
    answered_ids = (game.checklist_answers || []).map { |a| a['item_id'].to_i }.sort
    return nil if answered_ids == required_ids

    'Die Spieltagscheckliste muss vollständig ausgefüllt sein, bevor der Spielbericht abgeschlossen werden kann.'
  end

  def _maybe_send_checklist_confirmation(game)
    # Beide Mails hängen an derselben Checkliste, nämlich der des LV des
    # Spielbetriebs (siehe Game#state_association). Sie bleiben dennoch getrennt,
    # weil sie unterschiedliche Empfänger und Bedingungen haben: die eine den
    # Ausrichterverein und hinterlegte Antworten, die andere das Gespann.
    _send_hosting_club_checklist_mail(game)
    _send_referee_portal_notice(game)
  end

  # Mail an den Ausrichterverein mit Token-Veto-Link. Empfänger ist der Verein,
  # maßgeblich für die Checkliste ist aber der LV des Spielbetriebs.
  def _send_hosting_club_checklist_mail(game)
    sa = game.state_association
    return unless sa&.checklist_items&.any?

    answers = game.checklist_answers || []
    return if answers.empty?

    hosting_club = game.game_day.club
    return if hosting_club&.notification_emails.blank?

    raw_token = SecureRandom.urlsafe_base64(32)
    game.update_columns(
      checklist_veto_token_digest: Digest::SHA256.hexdigest(raw_token),
      checklist_veto_submitted_at: nil,
      checklist_veto_answers: []
    )

    GameMailer.checklist_confirmation(game, sa, answers, hosting_club, raw_token).deliver_later
  end

  # Schiri-Mail mit Portal-Link – nur wenn der LV des Spielbetriebs eine Checkliste
  # hat. Pro Spielbericht-Abschluss; bei mehreren Spielen eines Spieltags kann das
  # mehrfach pro Schiri auslösen (Link zeigt stets denselben Spieltag).
  def _send_referee_portal_notice(game)
    return unless game.state_association&.checklist_items&.any?

    assignment = game.referee_assignment
    emails = [assignment&.referee1&.email, assignment&.referee2&.email].reject(&:blank?).uniq
    return if emails.empty?

    GameMailer.checklist_referee_portal_notice(game, emails).deliver_later
  end

  def show_checklist_veto
    game = Game.find(params[:id])
    return render json: { error: 'Ungültiger Link.' }, status: :unauthorized unless valid_veto_token?(game, params[:token])

    sa = game.state_association
    items = sa&.checklist_items&.order(:position).to_a || []

    render json: {
      already_submitted: game.checklist_veto_submitted_at.present?,
      submitted_at: game.checklist_veto_submitted_at&.iso8601,
      game_number: game.game_number,
      home_team_name: game.home_team_name,
      guest_team_name: game.guest_team_name,
      date: game.game_day.date,
      original_answers: game.checklist_answers || [],
      checklist_items: items.map { |i| { id: i.id, question: i.question } }
    }
  end

  def submit_checklist_veto
    game = Game.find(params[:id])
    return render json: { error: 'Ungültiger Link.' }, status: :unauthorized unless valid_veto_token?(game, params[:token])

    if game.checklist_veto_submitted_at.present?
      return render json: { error: 'Ein Einspruch wurde bereits eingereicht.' }, status: :unprocessable_entity
    end

    raw = params.require(:answers)
    # Shape zuerst: `.map` auf etwas anderem als einer Liste (oder auf einer
    # Liste von Strings) stirbt sonst in `permit` und wird zum 500er samt
    # Sentry-Eintrag auf einem öffentlichen Endpunkt.
    unless raw.is_a?(Array) && raw.all? { |a| a.respond_to?(:permit) }
      return render json: { error: 'Ungültiges Format.' }, status: :unprocessable_entity
    end

    answers = _normalized_veto_answers(game, raw)
    return render json: { error: 'Ungültiges Format.' }, status: :unprocessable_entity if answers.nil?

    game.update_columns(checklist_veto_answers: answers, checklist_veto_submitted_at: Time.current)

    _send_checklist_veto_notification(game)

    render json: { success: true }
  end

  # Normalisiert die eingereichten Einspruchs-Antworten gegen die Checklisten-Items
  # des Landesverbands. nil, wenn der Einspruch nicht genau einmal jede Frage mit
  # true/false beantwortet.
  #
  # Streng, weil update_columns den Antwortsatz vollständig ersetzt und die
  # Benachrichtigung ihn als „Vollständige neue Bewertung" verschickt: Eine
  # Teilmenge würde die übrigen Fragen stillschweigend unterschlagen, eine doppelte
  # id dieselbe Frage zweimal mit widersprüchlichen Antworten zeigen. Ein String
  # "false" ist in Ruby wahr und hätte die Mail das Gegenteil behaupten lassen.
  #
  # `question` kommt bewusst aus der Datenbank, nicht aus der Anfrage: der Text
  # steht in einer Mail an das betroffene Gespann und darf nicht vom Absender
  # des Einspruchs bestimmt werden.
  def _normalized_veto_answers(game, raw)
    # Gleiche Quelle wie show_checklist_veto, sonst prüft der Server gegen einen
    # anderen Fragensatz als die Seite anzeigt und weist jeden Einspruch als
    # unvollständig ab.
    items = game.state_association&.checklist_items&.order(:position).to_a || []
    return nil if items.empty?

    submitted = raw.map { |a| a.permit(:item_id, :question, :answer).to_h }
    by_id = {}
    submitted.each do |answer|
      return nil unless [true, false].include?(answer['answer'])

      id = answer['item_id'].to_i
      return nil if by_id.key?(id)

      by_id[id] = answer['answer']
    end

    return nil unless by_id.keys.sort == items.map(&:id).sort

    items.map { |item| { 'item_id' => item.id, 'question' => item.question, 'answer' => by_id[item.id] } }
  end

  def _send_checklist_veto_notification(game)
    # Benachrichtigt wird die SBK des Spielbetriebs, nicht die des
    # Ausrichter-LV: nur sie verantwortet die Liga, in der gespielt wurde.
    sa = game.state_association
    return unless sa

    assignment = game.referee_assignment
    r1 = assignment&.referee1
    r2 = assignment&.referee2
    hosting_club = game.game_day.club

    GameMailer.checklist_veto_notification(game, sa, game.checklist_veto_answers, hosting_club, r1, r2).deliver_later
  end

  def valid_veto_token?(game, token)
    token.present? && game.checklist_veto_token_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(token),
        game.checklist_veto_token_digest
      )
  end

  def _maybe_send_incident_report_reminder(game)
    # Ohne den digitalen Berichtsworkflow bleibt es beim analogen Vor-Ort-Prozess
    # (Papierbericht) – dann ist auch keine 24h-Frist zu melden.
    return unless game.report_form_workflow_enabled?

    has_spielausschluss = (game.events || []).any? { |e| e['penalty_id'].to_s == '5' }
    return unless game.special_event? || has_spielausschluss

    assignment = game.referee_assignment
    return unless assignment

    r1 = assignment.referee1
    r2 = assignment.referee2
    return unless r1 && r2

    deadline = Time.current + 24.hours
    RefereeMailer.incident_report_reminder(r1, r2, game, deadline).deliver_later
  end

  def _secretary_permissions(game)
    return [] unless secretary_token_permits_game?(game)

    SECRETARY_PERMISSIONS
  end

  def _checklist_hash(game)
    sa = game.state_association
    items = sa&.checklist_items&.to_a || []
    {
      checklist_active: items.any?,
      checklist_items: items.map { |i| { id: i.id, question: i.question, position: i.position } },
      checklist_answers: game.checklist_answers || []
    }
  end

  # Rolle und Token sind additiv, nicht alternativ (#428). Vorher entschied ein
  # gesetzter `@secretary_link` allein: Ein Vereinsmanager mit einem gültigen
  # Hallen-Token in der Registerkarte verlor damit seine normalen Rechte an jedem
  # Spiel AUSSERHALB der vom Link abgedeckten Spieltage. Weil `show` es umgekehrt
  # hielt (dort gewann der Login), zeigte die Oberfläche die Bedienelemente der
  # eigenen Rolle, und der Schreibweg dahinter sagte nein.
  def can_edit_game?(game)
    return true if @secretary_link && secretary_token_permits_game?(game)
    return false unless current_user

    game.can_edit_lineup?(current_user)
  end

  # Admin oder SBK *des Spielbetriebs dieses Spiels*. Entscheidet, wer die
  # Sperre bei abgeschlossenem Spielbericht übergehen und ihn wieder öffnen
  # darf. Bewusst auf den Spielbetrieb gescopt (#214): sonst hebelt eine
  # fachfremde SBK-Rolle die Sperre aus, sobald der Nutzer über eine andere
  # Rolle (VM/TM einer beteiligten Mannschaft) ohnehin Zugriff auf das Spiel
  # hat. Muster übernommen aus reopen_game, das das bereits richtig machte.
  def admin_or_scoped_sbk?(game)
    ph = current_user&.permission_hash || {}
    gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
    return true if gos.include?(0)

    go_id = game.game_day&.league&.game_operation_id
    go_id.present? && gos.include?(go_id.to_i)
  end

  # Admin/SBK des Spielbetriebs, VM/TM der beteiligten Mannschaften (inkl.
  # Spielgemeinschafts-Vereine) sowie der VM des ausrichtenden Vereins dürfen
  # die internen Felder lesen.
  def can_view_hidden_elements?(game)
    # Spielsekretariat per Einmal-Link: darf genau die Spiele der Spieltage
    # sehen, die der Link abdeckt (eine Halle an einem Tag, gegebenenfalls
    # mehrere Ligen). Es bearbeitet ohnehin schon den Spielbericht dieser Spiele
    # (siehe SECRETARY_ACTIONS), braucht die internen Felder also, um sie zu
    # füllen. Additiv wie in can_edit_game?, siehe dort (#428).
    return true if @secretary_link && secretary_token_permits_game?(game)

    # Ohne Login und ohne Token gibt es nichts zu zeigen. Vorher lief das in ein
    # NoMethodError auf nil, sobald die Action ohne current_user erreichbar war.
    return false unless current_user

    ph = current_user.permission_hash
    go_id = game.league&.game_operation_id.to_i
    return true if ph[:admin].to_a.intersect?([0, go_id]) || ph[:sbk].to_a.intersect?([0, go_id])

    teams = [game.home_team, game.guest_team].compact
    return true if ph[:tm].present? && ph[:tm].intersect?(teams.map(&:id))

    # Der ausrichtende Verein gehört dazu, genau wie in Game#can_edit_lineup?
    # und Game#user_permissions. Ohne ihn bekäme der Ausrichter eines Turniers
    # an einem Ort ein leeres Formular, in das er zwar schreiben darf (siehe
    # set_string), dessen bereits eingetragene Werte er aber nicht sieht: das
    # Spielsekretariat, den Zeitnehmer, die Betreuer und den Vermerk der
    # Schiedsrichter. Das war die zweite Hälfte des Fehlers vom 15.08.
    club_ids = teams.flat_map(&:all_club_ids).compact + [game.game_day&.club_id].compact
    ph[:vm].present? && ph[:vm].intersect?(club_ids)
  end

  def author_user_id
    secretary_or_current_user_id
  end

  # Ein Tor ist entweder erzielt oder zugesprochen: technisches Tor und
  # Strafschuss (Pseudo-Strafcode 23) schließen sich aus.
  #
  # Greift ausschließlich bei Aufrufen, die beide Markierungen zugleich
  # schicken. Das Formular tut das nicht, es koppelt die Haken; und beim
  # Umstellen eines bestehenden Strafschusses ist der Code schon weg, bevor
  # diese Methode läuft (update_event überschreibt penalty_code_id
  # unconditional mit `.presence`, also mit nil). Übrig bleibt der Fall, den
  # sonst nichts abfängt: ein direkter API-Aufruf oder ein veralteter Client
  # mit beiden Feldern im selben Request. Ohne die Bereinigung stünden im
  # Ereignis zwei einander ausschließende Markierungen, und welche gewinnt,
  # entschiede allein die Reihenfolge der Zweige in formatted_events.
  #
  # Gelöscht wird mit String-Key, das greift in beiden Schreibwegen:
  # update_event ändert den string-keyed Hash aus dem JSONB, add_event einen
  # HashWithIndifferentAccess (der normalisiert Symbol-Keys auf Strings, sonst
  # liefe die Löschung dort ins Leere).
  def drop_penalty_shot_marker!(event)
    return unless Game.technical_goal?(event)

    event.delete('penalty_code_id')
  end

  # Die vier Angaben, die ein Ereignis überhaupt erst zu einem Ereignis machen.
  # Beide Schreibwege übernahmen sie ungeprüft aus den Parametern, ohne permit,
  # ohne .presence und ohne Wertebereich. Fehlte event_type oder kam es leer an,
  # verlor die Zeile ihre Kennzeichnung, und weil sort_events! den Spielstand nur
  # bei event_type == 'goal' hochzählt, sank der Spielstand still um ein Tor.
  # Kein Fehler, keine Meldung: Game#result überspringt Zeilen ohne Spielstand,
  # die Anzeige wirkte also stimmig, nur mit einem Tor weniger. Dieselben Zeilen
  # bleiben als typlose Rümpfe in events stehen.
  #
  # Anders als in #295 vermutet ist update_event nicht der einzige Weg dorthin:
  # add_event schreibt event_type genauso unbedingt aus den Parametern und legt
  # bei fehlendem Wert eine typlose Zeile gleich neu an. Beide Aktionen fragen
  # deshalb denselben Guard.
  #
  # Kein Risiko für bestehende Aufrufer: Das Spielbericht-Formular
  # (match-event-form) ist der einzige Schreibweg und setzt alle vier Werte fest
  # ('goal' oder 'penalty', 'home' oder 'guest', Zeit, Abschnitt). Die v1-Ticker-
  # Schnittstelle liest nur.
  EVENT_TYPES = %w[goal penalty].freeze
  EVENT_TEAMS = %w[home guest].freeze

  # Gibt eine erklärende Meldung zurück oder nil, wenn die Angaben tragen
  # (gleiche Form wie logo_upload_error).
  #
  # Der Abgleich gegen eine Werteliste erledigt bei event_type und event_team
  # zugleich die Typfrage: Ein Array oder ein verschachtelter Parameter steht
  # nicht in der Liste und fällt heraus. Bei Zeit und Abschnitt genügt eine
  # reine Anwesenheitsprüfung dafür NICHT, deshalb dort zusätzlich der Typ.
  def event_input_error
    unless EVENT_TYPES.include?(params[:event_type])
      return 'Ereignisart fehlt oder ist unbekannt (erlaubt: Tor oder Strafe).'
    end
    unless EVENT_TEAMS.include?(params[:event_team])
      return 'Mannschaft fehlt oder ist unbekannt (erlaubt: Heim oder Gast).'
    end
    # Die Zeit ist immer eine Zeichenkette ("mm:ss"), das Formular baut sie so
    # zusammen. Als Array kam sie ungeprüft durch und stand danach als
    # ["20:00"] im JSONB.
    return 'Ereigniszeit fehlt.' unless params[:time].is_a?(String) && params[:time].present?
    return 'Spielabschnitt fehlt.' unless valid_period?(params[:period])

    nil
  end

  # Der Abschnitt kommt vom Formular als JSON-Zahl (`parseInt` im Frontend), bei
  # einem Formular-Post als Zeichenkette. Beides ist in Ordnung, ein Array nicht:
  # sort_events! sortiert über [period, time, id, row], und ein Array neben einer
  # Zeichenkette lässt den Vergleich mit "comparison of Array with Array failed"
  # abbrechen – ein 500er, ausgelöst allein durch die Nutzlast.
  def valid_period?(value)
    case value
    when Integer then true
    when String then value.present?
    else false
    end
  end

  # Weicher Lizenz-Check: erzeugt eine Warnmeldung, wenn der Spieler keine erteilte
  # Lizenz fuer das Team in der Liga des Spiels hat. Blockiert das Hinzufuegen nicht.
  def lineup_license_warning(game, player, side)
    return nil if player.nil?

    team_id = side == 'home' ? game.home_team_id : game.guest_team_id
    return nil if team_id.blank?

    license = player.licenses_by_team(team_id)
    return "Kein Lizenzantrag für #{player.first_name} #{player.last_name} im aufstellenden Team" if license.blank?

    last_status = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
    if last_status != License::APPROVED
      status_name = License::NAMES[last_status] || 'unbekannt'
      return "Lizenz von #{player.first_name} #{player.last_name} ist nicht erteilt (Status: #{status_name})"
    end

    # String-Vergleich der Ligaklassen-Codes (1fbl/2fbl/rl/vl/ll). Wettbewerbe
    # ohne Ligaklasse (DM, Pokal, Trophy: league_class_id leer) werden nicht
    # geprüft — dort treten Teams mit Lizenzen ihrer Stammliga an.
    game_league = game.league
    if game_league&.league_class_id.present? && license['league_class_id'].present? &&
       license['league_class_id'].to_s != game_league.league_class_id.to_s
      return "Lizenzklasse von #{player.first_name} #{player.last_name} passt nicht zur Spielklasse"
    end

    nil
  end

  def game_flag_params
    params.require(:game).permit(:started, :ended,
                                 :time_keeper_signed, :record_keeper_signed, :referee1_signed, :referee2_signed,
                                 :protest, :special_event, :playoff, :overtime,
                                 :home_captain_signed, :guest_captain_signed)
  end

  def game_value_params
    params.require(:game).permit(:audience, :actual_start_time, :live_stream_link, :vod_link,
                                 :home_timeout_string, :guest_timeout_string,
                                 :time_keeper_string, :record_keeper_string, :record_comment, :special_event_string)
  end

  def game_create_update_params
    params.require(:game).permit(:forfait, :game_day_id, :game_number, :start_time,
                                 :nominated_referee_string, :person_level_assignment,
                                 :notice_type, :notice_string,
                                 :home_team_id, :guest_team_id,
                                 :group_identifier,
                                 :series_title,
                                 :series_number,
                                 :home_team_filling_rule,
                                 :home_team_filling_parameter,
                                 :guest_team_filling_rule,
                                 :guest_team_filling_parameter,
                                 nominated_referee_ids: [])
  end

  # Spielverwaltung ist Admins und SBK (global oder im Verband des Spiels) erlaubt
  # — gleiche Logik wie bei create/update.
  def game_scheduling_allowed?(league)
    ph = current_user.permission_hash
    return false unless ph[:admin].present? || ph[:sbk].present?

    gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
    gos.include?(0) || gos.include?(league.game_operation_id.to_i)
  end

  def scheduling_conflict_hash(game)
    {
      id: game.id,
      game_number: game.game_number,
      start_time: game.start_time,
      home_team: game.home_team_name,
      guest_team: game.guest_team_name,
      league_name: game.league.name
    }
  end

  def _maybe_send_game_day_scan_reminder(game)
    game_day = game.game_day
    return unless game.state_association&.scan_required?

    all_closed = game_day.games.reload.all? do |g|
      %w[match_record_closed finalized].include?(g.game_status)
    end
    return unless all_closed

    hosting_club = game_day.club
    return if hosting_club&.notification_emails.blank?

    ClubMailer.game_day_scan_reminder(hosting_club, game_day).deliver_later
  end
end
