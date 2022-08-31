class ClubsController < ApplicationController
  # GET /clubs
  def index
    @clubs = Clubs.all

    render json: @clubs
  end

  def admin_get_go_clubs
    if current_user
      league = if params[:callType] == 'l'
                 League.find(params[:id])
               else
                 team = Team.find(params[:id])
                 team&.league
               end

      game_operation = league&.game_operation
      if game_operation && game_operation&.user_permissions(current_user)&.include?(:index_clubs)
        render json: game_operation.clubs.map(&:full_hash)
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end
end
