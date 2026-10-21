# Hielt die Anmeldung beim Abmelden einen Platz? Nur dann ist eine Abmeldung
# nach der Frist abrechenbar. Wer von der Warteliste abspringt, hatte nie einen
# Platz und schuldet nichts.
class AddHeldSeatAtCancelToRefereeCourseRegistrations < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_registrations, :held_seat_at_cancel, :boolean, null: false, default: false
  end
end
