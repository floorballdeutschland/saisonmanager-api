class TeamsController < ApplicationController
  # GET /teams
  def index
    @teams = Team.all

    render json: @teams
  end

  def admin_get_team
    if current_user
      team = Team.find(params[:id])

      if team
        render json: team.full_hash(true)
      else
        render json: { error: 'Keine passendes Team gefunden.' }, status: :not_found
      end
    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_team_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create team for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      l = League.find(params[:league_id])

      if create_modus && League.find(params[:league_id])&.game_operation&.user_permissions(current_user)&.include?(:create_team) # create

        tp = team_params
        team = Team.create(tp)

        render json: team, status: :created
      elsif !create_modus && Team.find(params[:id])&.user_permissions(current_user)&.include?(:update_team) # update
        # update
        team = Team.find(params[:id])
        if team.update(team_params)
          render json: team
        else
          render json: team.errors, status: :unprocessable_entity
        end
      else
        render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { error: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def team_params
    params.require(:team).permit(:club_id, :contact_email, :contact_person, :league_id, :name, :short_name, :syndicate,
                                 syndicate_clubs: [])
  end
end
