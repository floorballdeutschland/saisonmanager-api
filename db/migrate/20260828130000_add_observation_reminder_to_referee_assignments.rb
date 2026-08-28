# Idempotenz-Marke für die Erinnerung an den Schiedsrichtercoach. Sie hängt an
# der Ansetzung und nicht am Spiel: Erinnert wird der angesetzte Coach, und pro
# Spiel gibt es genau eine Ansetzung (Unique-Index auf game_id).
class AddObservationReminderToRefereeAssignments < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_assignments, :observation_reminder_sent_at, :datetime
  end
end
