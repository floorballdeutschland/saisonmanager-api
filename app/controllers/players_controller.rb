class PlayersController < ApplicationController
  before_action :set_player, only: %i[show update destroy]

  # GET /players
  def index
    @players = Player.all.order(:last_name).order(:first_name).where("last_name != '' AND first_name != ''").order(:birthdate)
  end

  # GET /players/1
  def show; end

  def admin_players_index
    if current_user
      result = Player.admin_user_players(current_user, params[:club_id])

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_player
    if current_user
      result = Player.find(params[:id])

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  private

  def set_player
    @player = Player.find(params[:id])
  end
end
