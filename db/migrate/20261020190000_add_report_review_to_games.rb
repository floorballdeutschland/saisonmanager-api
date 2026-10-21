# Erledigt-Vermerk der SBK an einem Spielbericht (Arbeitsansicht
# „Spielberichte"), optional mit Kommentar. Ohne ihn blieb jede Auffälligkeit
# und jeder Einspruch stehen, bis der Spieltag aus der Ansicht fiel, und die
# SBK konnte nicht sehen, was schon bearbeitet war.
class AddReportReviewToGames < ActiveRecord::Migration[7.2]
  def change
    add_column :games, :report_reviewed_at, :datetime
    add_column :games, :report_reviewed_by_user_id, :integer
    add_column :games, :report_review_comment, :text
  end
end
