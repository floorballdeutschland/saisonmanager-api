# Bestaetigung einer Selbstanmeldung durch den zahlenden Verein.
class AddClubConfirmationToRefereeCourseRegistrations < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_registrations, :club_confirmed_at, :datetime
    add_reference :referee_course_registrations, :club_confirmed_by_user, foreign_key: { to_table: :users }
    add_column :referee_course_registrations, :club_decline_reason, :text
  end
end
