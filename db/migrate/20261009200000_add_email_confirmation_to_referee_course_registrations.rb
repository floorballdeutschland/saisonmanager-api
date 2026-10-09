# Oeffentliche Kursanmeldung: Bestaetigung per Mail (Double-Opt-in) mit Ablauf.
class AddEmailConfirmationToRefereeCourseRegistrations < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_registrations, :email_confirmation_expires_at, :datetime
    add_column :referee_course_registrations, :email_confirmed_at, :datetime
  end
end
