class GamesController < ApplicationController
  skip_before_action :authenticate_user

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
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
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

  def set_captain
    game = Game.find(params[:id])
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
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
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
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

  def add_event
    game = Game.find(params[:id])
    # check if allowed

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      # ensure we have the hash set
      game.events ||= []

      max_row = game.events.map { |e| e['row'] }.max

      item = {
        row: max_row + 1,
        time: params[:time],
        period: params[:period],
        home_goals: params[:home_goals],
        guest_goals: params[:guest_goals]
      }

      item[:home_number] = params[:home_number] if params[:home_number].present?
      item[:home_assist] = params[:home_assist] if params[:home_assist].present?
      item[:guest_number] = params[:guest_number] if params[:guest_number].present?
      item[:guest_assist] = params[:guest_assist] if params[:guest_assist].present?

      item[:event_type] = params[:event_type]

      case params[:event_type]
      when 'penalty'
        item[:penalty_id] = params[:penalty_id]
        item[:penalty_code_id] = params[:penalty_code_id]
      when 'goal'
        item[:goal_type] = params[:goal_type] if params[:goal_type].present?
        item[:penalty_code_id] = params[:penalty_code_id] if params[:penalty_code_id].present?
      end

      game.events << item

      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

      if game.save
        render json: game.events
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
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
                  ph[:vm].intersection([game.home_team.syndicate_clubs,
                                        game.guest_team.syndicate_clubs].flatten.compact).present?
              elsif ph[:tm].present?
                ph[:tm].include?(game.home_team_id) || ph[:tm].include?(game.guest_team_id)
              end

    if allowed
      # ensure we have the hash set
      game.events ||= []

      game.events.reject! do |p|
        p['row'].to_i == params[:row]
      end
      game.record_created_at ||= Time.now
      game.record_updated_at = Time.now
      game.record_created_by ||= current_user.id
      game.record_updated_by = current_user.id

      if game.save
        render json: game.events
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
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
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
                ph[:vm].intersection?([game.home_team.club_id, game.guest_team.club_id]) ||
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

  def game_flag_params
    params.require(:game).permit(:started, :ended,
                                 :time_keeper_signed, :record_keeper_signed, :referee1_signed, :referee2_signed,
                                 :protest, :special_event, :playoff, :overtime,
                                 :home_captain_signed, :guest_captain_signed)
  end

  def game_value_params
    params.require(:game).permit(:audience, :start_time,
                                 :guest_timeout_string, :referee1_signed,
                                 :time_keeper_string, :record_keeper_string)
  end
end
