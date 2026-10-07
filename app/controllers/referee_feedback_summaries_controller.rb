# Das Vereins-Feedback aus Sicht der bewerteten Person: nur die drei Kennzahlen
# (Anzahl, Schnitt Linie, Schnitt Kommunikation), nie die einzelnen
# Rückmeldungen, Freitexte oder Mannschaften. Die bleiben der Schiedsrichter-
# verwaltung vorbehalten (Admin::RefereesController#feedbacks).
#
# Die Schwelle setzt bewusst die API durch und nicht erst die Anzeige: Stünden
# die Mittelwerte unterhalb von MIN_COUNT in der Antwort, ließe sich bei zwei
# oder drei Rückmeldungen ablesen, welche Mannschaft wie bewertet hat.
#
# Oberhalb der Schwelle zählen nur volle Fünferblöcke (die ältesten
# floor(n/5)*5 sichtbaren Rückmeldungen). Sonst ließe sich jede neue Bewertung
# aus der Differenz zweier Abrufe zurückrechnen: Die Bewertungen sind ganzzahlig,
# die Rundung auf 0,1 verdeckt bei wenigen Rückmeldungen nichts, und die Person
# weiß, wer im letzten Spiel gespielt hat. Mit Blöcken verrät eine Differenz
# höchstens den Schnitt von fünf Rückmeldungen. Auch die Anzahl bezieht sich auf
# den Block, damit sie das Eintreffen einer Bewertung nicht neben die Mittelwerte
# stellt. Unter der Schwelle gibt es keine Mittelwerte, dort steht die echte
# Anzahl (sie verrät nur, dass abgegeben wurde, nicht wie).
class RefereeFeedbackSummariesController < ApplicationController
  before_action :authenticate_user

  MIN_COUNT = 5

  # GET /api/v2/referee/feedback_summary
  def show
    referee = current_user.referee
    return render json: { error: 'Kein Schiedsrichterprofil gefunden' }, status: :forbidden unless referee

    ratings = RefereeFeedback.visible.for_referee(referee.id)
                             .order(:created_at, :id)
                             .pluck(:line_rating, :communication_rating)
    return render json: summary_json(ratings.size, nil, nil) if ratings.size < MIN_COUNT

    block = ratings.first((ratings.size / MIN_COUNT) * MIN_COUNT)
    render json: summary_json(block.size, average(block.map(&:first)), average(block.map(&:last)))
  end

  private

  def summary_json(count, avg_line, avg_communication)
    {
      count: count,
      min_count: MIN_COUNT,
      avg_line_rating: avg_line,
      avg_communication_rating: avg_communication
    }
  end

  def average(values)
    (values.sum.to_f / values.size).round(1)
  end
end
