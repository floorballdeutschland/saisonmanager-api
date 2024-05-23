class GamesController < ApplicationController
  skip_before_action :authenticate_user, only: %i[index show]

  # GET /games
  def index
    @games = Game.all
  end

  # GET /games/1
  def show
    game = Game.find(params[:id])

    hash = game.full_hash
    hash[:permission] = game.user_permissions(current_user) if current_user

    render json: hash
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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

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
        else
          item[:player_firstname] = params[:player_firstname]
          item[:player_name] = params[:player_name]
        end

        game.players[side] << item

        game.record_created_at ||= Time.now
        game.record_updated_at = Time.now
        game.record_created_by ||= current_user.id
        game.record_updated_by = current_user.id

        if game.save
          render json: game.players[side]
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

    # Check if allowed
    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]).present? ||
                ph[:vm].intersection([game.home_team.syndicate_clubs, game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              else
                false
              end

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
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

      if game.save
        render json: game.starting_players_with_numbers
      else
        render json: { message: game.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def add_coach
    game = Game.find(params[:id])
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      side = params[:side]

      # ensure we have the hash set
      game.home_team_coaches ||= {}
      game.guest_team_coaches ||= {}

      last_name = params[:last_name].strip
      first_name = params[:first_name].strip

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
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

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
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

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
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      side = params[:side]

      # ensure we have the hash set
      game.home_team_coaches ||= {}
      game.guest_team_coaches ||= {}

      prefix = "coach#{params[:number]}"
      if side == 'home'
        game.home_team_coaches.reject! { |k, _v| k.starts_with?(prefix) }
      else
        game.guest_team_coaches.reject! { |k, _v| k.starts_with?(prefix) }
      end

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
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
        guest_goals: params[:guest_goals]
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

      game.events << item

      game.sort_events!

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
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
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

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

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id
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
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

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
      game.record_updated_by = current_user.id

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
    # check if allowed

    ph = current_user.permission_hash
    sbk = false
    allowed = if ph[:admin].present? || ph[:sbk].present?
                sbk = true
                true
              elsif ph[:vm].present?
                ph[:vm].intersection([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      if params[:game_status].present?
        old_status = game.game_status
        game.game_status = params[:game_status]

        # TODO: check order
        # TODO: check if allowed to set new status?
        game.save
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
    if current_user && %w[jho_admin buettner_sbk mguenther].include?(current_user.user_name)
      game = Game.find(params[:id])
      game.update(game_status: 'match_record_closed')

      render json: { success: true }
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
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
                                 :time_keeper_string, :record_keeper_string, :record_comment)
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
                                 :guest_team_filling_parameter)
  end
end
