# Einwilligung der Erziehungsberechtigten per Link (unter 16) und die Herkunft
# einer Anmeldung (Verwaltung, Portal, Verein, oeffentliches Formular).
#
# up/down statt change: remove_index ueber den Namen ist nicht umkehrbar.
class AddGuardianTokenToRefereeCourseRegistrations < ActiveRecord::Migration[7.2]
  ACTIVE = "status NOT IN ('cancelled_by_participant', 'cancelled_by_organizer')".freeze
  PERSON_COLUMNS = 'referee_course_id, lower(email), geburtsdatum, lower(vorname)'.freeze

  def up
    add_column :referee_course_registrations, :guardian_token_digest, :string
    add_column :referee_course_registrations, :guardian_token_expires_at, :datetime
    add_column :referee_course_registrations, :source, :string, null: false, default: 'admin',
                                                                comment: 'admin, portal, club, public'
    add_index :referee_course_registrations, :guardian_token_digest, unique: true

    # Abgemeldete Zeilen bleiben stehen (Abrechnung, Nachvollziehbarkeit). Sie
    # duerfen eine erneute Anmeldung derselben Person nicht sperren.
    replace_unique_indexes(where_referee: "referee_id IS NOT NULL AND #{ACTIVE}",
                           where_person: "email IS NOT NULL AND #{ACTIVE}")
  end

  def down
    replace_unique_indexes(where_referee: 'referee_id IS NOT NULL', where_person: 'email IS NOT NULL')
    remove_index :referee_course_registrations, :guardian_token_digest
    remove_column :referee_course_registrations, :source
    remove_column :referee_course_registrations, :guardian_token_expires_at
    remove_column :referee_course_registrations, :guardian_token_digest
  end

  private

  def replace_unique_indexes(where_referee:, where_person:)
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_referee'
    add_index :referee_course_registrations, %i[referee_course_id referee_id], unique: true, where: where_referee,
                                                                              name: 'idx_course_registrations_unique_referee'
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_person'
    add_index :referee_course_registrations, PERSON_COLUMNS, unique: true, where: where_person,
                                                             name: 'idx_course_registrations_unique_person'
  end
end
