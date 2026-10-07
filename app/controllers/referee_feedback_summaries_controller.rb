# Das Vereins-Feedback aus Sicht der bewerteten Person: nur die drei Kennzahlen
# (Anzahl, Schnitt Linie, Schnitt Kommunikation), nie die einzelnen
# Rückmeldungen, Freitexte oder Mannschaften. Die bleiben der Schiedsrichter-
# verwaltung vorbehalten (Admin::RefereesController#feedbacks).
#
# Die Schwelle setzt bewusst die API durch und nicht erst die Anzeige: Stünden
# die Mittelwerte unterhalb von MIN_COUNT in der Antwort, ließe sich bei zwei
# oder drei Rückmeldungen ablesen, welche Mannschaft wie bewertet hat.
class RefereeFeedbackSummariesController < ApplicationController
  before_action :authenticate_user

  MIN_COUNT = 5

  # GET /api/v2/referee/feedback_summary
  def show
    referee = current_user.referee
    return render json: { error: 'Kein Schiedsrichterprofil gefunden' }, status: :forbidden unless referee

    ratings = RefereeFeedback.visible.for_referee(referee.id)
                             .pluck(:line_rating, :communication_rating)
    enough = ratings.size >= MIN_COUNT

    render json: {
      count: ratings.size,
      min_count: MIN_COUNT,
      avg_line_rating: enough ? average(ratings.map(&:first)) : nil,
      avg_communication_rating: enough ? average(ratings.map(&:last)) : nil
    }
  end

  private

  def average(values)
    (values.sum.to_f / values.size).round(1)
  end
end
