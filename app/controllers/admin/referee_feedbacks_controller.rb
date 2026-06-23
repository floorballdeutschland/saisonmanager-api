module Admin
  # Moderation des Schiri-Feedbacks. Unsachliche Rückmeldungen werden hier
  # ausgeblendet (status: 'hidden') und fließen dann nicht mehr in die
  # Durchschnitte am Schiri-Profil ein. Nur Admin / FD-RSK / FD-Ansetzer.
  class RefereeFeedbacksController < ApplicationController
    before_action :authorize_feedback_moderation!

    # PATCH /api/v2/admin/referee_feedbacks/:id
    def update
      feedback = RefereeFeedback.find(params[:id])
      status = params[:status].to_s

      unless %w[visible hidden].include?(status)
        return render json: { error: 'Ungültiger Status' }, status: :unprocessable_entity
      end

      feedback.update!(status: status)
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def authorize_feedback_moderation!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present? && ph[:rsk].include?(0)
      return if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
