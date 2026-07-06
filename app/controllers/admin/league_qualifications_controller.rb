module Admin
  class LeagueQualificationsController < ApplicationController
    before_action :set_league
    before_action :authorize_league_update!

    # POST /api/v2/admin/leagues/:league_id/qualifications
    def create
      qual = @league.qualifications.build(qualification_params)
      if qual.save
        render json: qual_hash(qual), status: :created
      else
        render json: { errors: qual.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /api/v2/admin/leagues/:league_id/qualifications/:id
    def update
      qual = @league.qualifications.find(params[:id])
      if qual.update(qualification_params)
        render json: qual_hash(qual)
      else
        render json: { errors: qual.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Nicht gefunden' }, status: :not_found
    end

    # DELETE /api/v2/admin/leagues/:league_id/qualifications/:id
    def destroy
      qual = @league.qualifications.find(params[:id])
      qual.destroy
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Nicht gefunden' }, status: :not_found
    end

    private

    def set_league
      @league = League.find(params[:league_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Liga nicht gefunden' }, status: :not_found
    end

    def qualification_params
      params.require(:league_qualification).permit(:rank_from, :rank_to, :qualification_type, :label, :target_league_id)
    end

    def qual_hash(qual)
      {
        id: qual.id,
        rank_from: qual.rank_from,
        rank_to: qual.rank_to,
        qualification_type: qual.qualification_type,
        label: qual.label,
        target_league_id: qual.target_league_id,
        target_league_name: qual.target_league&.name
      }
    end

    # Qualifikationsregeln sind Teil der Liga-Bearbeitung und daher denselben
    # Nutzern erlaubt wie das Bearbeiten der Liga selbst (admin || SBK im
    # Spielbetrieb der Liga) – nicht nur Admin.
    def authorize_league_update!
      return if @league.user_permissions(current_user).include?(:update_league)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
