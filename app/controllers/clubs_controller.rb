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

  def admin_club_index
    if current_user
      result = Club.admin_user_clubs(current_user)

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club
    if current_user
      result = Club.find(params[:id])

      render json: result.full_hash
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_club_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create club for that go?
      #   else : unpermitted!
      # check: club permission unless create_modus
      #   has: update club for that club?
      #   else : unpermitted!
      if create_modus && GameOperation.find(params[:game_operation_id])&.user_permissions(current_user)&.include?(:create_club) # create

        cp = club_params
        cp[:game_operation_hash] = [{ home_game_operation: true, game_operation_id: params[:game_operation_id] }]
        club = Club.create(cp)

        render json: club, status: :created
      elsif !create_modus && Club.find(params[:id])&.user_permissions(current_user)&.include?(:update_club) # update
        # update
        club = Club.find(params[:id])
        if club.update(club_params)
          render json: club
        else
          render json: club.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def club_params
    params.require(:club).permit(:name, :short_name, :long_name, :state)
  end
end
