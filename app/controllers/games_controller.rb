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

      side = params[:team_side]

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
end
