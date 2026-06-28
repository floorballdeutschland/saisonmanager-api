class GamesController < ApplicationController
  include SecretaryTokenAuthenticatable

  SECRETARY_ACTIONS = %i[
    add_player_to_lineup remove_player add_coach remove_coach set_captain
    set_starting_player set_player_award
    add_event remove_event update_event
    set_referee set_game_status set_flag set_string
    set_checklist_answers
  ].freeze

  VETO_ACTIONS = %i[show_checklist_veto submit_checklist_veto].freeze

  skip_before_action :authenticate_user, only: %i[index show] + SECRETARY_ACTIONS + VETO_ACTIONS
  before_action :authenticate_public_request, only: %i[index show] + VETO_ACTIONS
  before_action :authenticate_with_secretary_token_or_user, only: SECRETARY_ACTIONS

  # GET /games
  def index
    @games = Game.all
  end

  # GET /games/1
  def show
    game = Game.find(params[:id])

    if api_key_request? && !@api_key.realtime
      cutoff = Time.current.to_i - 10.minutes.to_i
      game.events = (game.events || []).select { |e| e['added_at'].nil? || e['added_at'] < cutoff }
    end

    hash = game.full_hash
    hash[:permission] = game.user_permissions(current_user) if current_user
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
      format.ics do
        ical = ::Icalendar::Calendar.new
        event = game.ical
        ical.add_event(event)

        require 'icalendar/tzinfo'
        tzid = 'Europe/Berlin'
        tz = TZInfo::Timezone.get tzid
        timezone = tz.ical_timezone event.dtstart
        ical.add_timezone timezone

        ical.append_custom_property('METHOD', 'REQUEST')
        ical.publish

        render plain: ical.to_ical
      end
    end
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

    if allowed
      if game.update(game_create_update_params)

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

  def show_hidden
    game = Game.find(params[:id])

    hash = game.hidden_elements

    render json: hash
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

  def update_start_end
    Game.start_end_games
  end

  def next_period_info
    game = Game.find(params[:id])
    league = game.league

    current_period = 0
    # prüfe ob events vorliegen, bestimme aktuelle periode
    current_period = game.events.map { |e| e['period'] }.max game.events.present?

    next_period = current_period + 1
    next_period_title = league.period_title next_period
    next_period_length = league.period_time next_period
    is_extratime = league.period_is_extratime next_period

    render json: {
      current_period:,
      next_period:,
      next_period_title:,
      next_period_length:,
      is_extratime:
    }
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
          birthdate = parse_player_birthdate(player.birthdate)
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

    ph = current_user&.permission_hash || {}
    admin_or_sbk = ph[:admin].present? || ph[:sbk].present?
    allowed = if !admin_or_sbk && game.match_record_closed?
                false
              else
                can_edit_game?(game)
              end

    if allowed
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

    ph = current_user&.permission_hash || {}
    admin_or_sbk = ph[:admin].present? || ph[:sbk].present?
    allowed = if !admin_or_sbk && game.match_record_closed?
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
    ph = current_user&.permission_hash || {}
    admin_or_sbk = ph[:admin].present? || ph[:sbk].present?
    allowed = if !admin_or_sbk && game.match_record_closed?
                false
              else
                can_edit_game?(game)
              end

    if allowed
      game.events ||= []
      event = game.events.find { |e| e['id'].to_i == params[:event_id].to_i }
      return render json: { message: 'Ereignis nicht gefunden.' }, status: :not_found unless event

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
    # check if allowed

    ph = current_user&.permission_hash || {}
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              else
                can_edit_game?(game)
              end

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

      game.referee_ids ||= []
      game.referee_ids[ref_num - 1] = (params[:license_id] || 0).to_i

      name = "#{game.referee_ids[ref_num - 1]} #{params[:lastname]}, #{params[:firstname]}"

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
    sbk = ph[:admin].present? || ph[:sbk].present?
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
    ph = current_user.permission_hash
    game_operation_id = game.game_day.league.game_operation_id.to_i

    gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
    unless gos.include?(0) || gos.include?(game_operation_id)
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
    sa = game.game_day.club&.state_association
    return nil unless sa&.checklist_items&.any?

    required_ids = sa.checklist_items.pluck(:id).sort
    answered_ids = (game.checklist_answers || []).map { |a| a['item_id'].to_i }.sort
    return nil if answered_ids == required_ids

    'Die Spieltagscheckliste muss vollständig ausgefüllt sein, bevor der Spielbericht abgeschlossen werden kann.'
  end

  def _maybe_send_checklist_confirmation(game)
    # Beide Mails unabhängig voneinander auslösen: Die Ausrichter-Mail hängt an
    # der Checkliste des Vereins-LV, die Schiri-Portal-Mail am LV der Liga – diese
    # können bei ligaübergreifenden Konstellationen abweichen.
    _send_hosting_club_checklist_mail(game)
    _send_referee_portal_notice(game)
  end

  # Ausrichter-Mail mit Token-Veto-Link (Checkliste des LV des Ausrichtervereins).
  def _send_hosting_club_checklist_mail(game)
    sa = game.game_day.club&.state_association
    return unless sa&.checklist_items&.any?

    answers = game.checklist_answers || []
    return if answers.empty?

    hosting_club = game.game_day.club
    return if hosting_club&.contact_email.blank?

    raw_token = SecureRandom.urlsafe_base64(32)
    game.update_columns(
      checklist_veto_token_digest: Digest::SHA256.hexdigest(raw_token),
      checklist_veto_submitted_at: nil,
      checklist_veto_answers: []
    )

    GameMailer.checklist_confirmation(game, sa, answers, hosting_club, raw_token).deliver_later
  end

  # Schiri-Mail mit Portal-Link – nur wenn der LV der Liga (maßgeblich fürs Portal)
  # eine Checkliste hat. Pro Spielbericht-Abschluss; bei mehreren Spielen eines
  # Spieltags kann das mehrfach pro Schiri auslösen (Link zeigt stets denselben Spieltag).
  def _send_referee_portal_notice(game)
    league_sa = game.game_day.league&.game_operation&.state_association
    return unless league_sa&.checklist_items&.any?

    assignment = game.referee_assignment
    emails = [assignment&.referee1&.email, assignment&.referee2&.email].reject(&:blank?).uniq
    return if emails.empty?

    GameMailer.checklist_referee_portal_notice(game, emails).deliver_later
  end

  def show_checklist_veto
    game = Game.find(params[:id])
    return render json: { error: 'Ungültiger Link.' }, status: :unauthorized unless valid_veto_token?(game, params[:token])

    sa = game.game_day.club&.state_association
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

    answers = params.require(:answers).map { |a| a.permit(:item_id, :question, :answer).to_h }
    game.update_columns(checklist_veto_answers: answers, checklist_veto_submitted_at: Time.current)

    _send_checklist_veto_notification(game)

    render json: { success: true }
  end

  def _send_checklist_veto_notification(game)
    sa = game.game_day.club&.state_association
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

  def _checklist_hash(game)
    sa = game.game_day.club&.state_association
    items = sa&.checklist_items&.to_a || []
    {
      checklist_active: items.any?,
      checklist_items: items.map { |i| { id: i.id, question: i.question, position: i.position } },
      checklist_answers: game.checklist_answers || []
    }
  end

  def can_edit_game?(game)
    return secretary_token_permits_game?(game) if @secretary_link
    return false unless current_user
    game.can_edit_lineup?(current_user)
  end

  def author_user_id
    secretary_or_current_user_id
  end

  # players.birthdate ist eine varchar-Spalte; direkter Vergleich mit Date schlägt fehl
  def parse_player_birthdate(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
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
                                 :nominated_referee_string, :notice_type, :notice_string,
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
    return unless game_day.league.game_operation.state_association&.scan_required?

    all_closed = game_day.games.reload.all? do |g|
      %w[match_record_closed finalized].include?(g.game_status)
    end
    return unless all_closed

    hosting_club = game_day.club
    return unless hosting_club&.contact_email.present?

    ClubMailer.game_day_scan_reminder(hosting_club, game_day).deliver_later
  end
end
