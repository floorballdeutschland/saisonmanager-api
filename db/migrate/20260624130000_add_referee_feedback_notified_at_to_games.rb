# Zeitstempel, wann die TMs über das verfügbare Schiri-Feedback-Formular dieses
# Spiels benachrichtigt wurden. NULL = noch nicht benachrichtigt (Idempotenz für
# den Benachrichtigungs-Task).
class AddRefereeFeedbackNotifiedAtToGames < ActiveRecord::Migration[7.1]
  def change
    add_column :games, :referee_feedback_notified_at, :datetime
  end
end
