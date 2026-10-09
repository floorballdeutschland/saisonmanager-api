# Einwilligung der Erziehungsberechtigten per Link (unter 16) und die Herkunft
# einer Anmeldung (Verwaltung, Portal, Verein, oeffentliches Formular).
class AddGuardianTokenToRefereeCourseRegistrations < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_registrations, :guardian_token_digest, :string
    add_column :referee_course_registrations, :guardian_token_expires_at, :datetime
    add_column :referee_course_registrations, :source, :string, null: false, default: 'admin',
                                                                comment: 'admin, portal, club, public'
    add_index :referee_course_registrations, :guardian_token_digest, unique: true

    # Abgemeldete Zeilen bleiben stehen (Abrechnung, Nachvollziehbarkeit). Sie
    # duerfen eine erneute Anmeldung derselben Person nicht sperren.
    active = "status NOT IN ('cancelled_by_participant', 'cancelled_by_organizer')"
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_referee'
    add_index :referee_course_registrations, %i[referee_course_id referee_id], unique: true,
                                                                              where: "referee_id IS NOT NULL AND #{active}",
                                                                              name: 'idx_course_registrations_unique_referee'
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_person'
    add_index :referee_course_registrations,
              'referee_course_id, lower(email), geburtsdatum, lower(vorname)',
              unique: true, where: "email IS NOT NULL AND #{active}", name: 'idx_course_registrations_unique_person'
  end
end
