# Sichtbarkeit des Schiri-Feedbacks: ausschließlich Admin sowie die global
# gescopten FD-Rollen (RSK/Ansetzer enthalten 0). Identisch zur Moderation
# (Admin::RefereeFeedbacksController) und zur Einzelsicht am Schiri-Profil.
module FeedbackVisibility
  extend ActiveSupport::Concern

  private

  def authorize_feedback_access!
    ph = current_user.permission_hash
    return if ph[:admin].present?
    return if ph[:rsk].present? && ph[:rsk].include?(0)
    return if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

    render json: { error: 'Nicht berechtigt' }, status: :forbidden
  end
end
