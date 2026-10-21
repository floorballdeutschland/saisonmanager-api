# Eine vom Verein abgelehnte Anmeldung (declined_by_club) sperrt keine neue
# Anmeldung derselben Person. Das Modell liess sie schon zu, die Teilindizes
# nicht: Die Neuanmeldung endete in einem RecordNotUnique (500).
class DeclinedByClubDoesNotBlockRegistration < ActiveRecord::Migration[7.2]
  PERSON_COLUMNS = 'referee_course_id, lower(email), geburtsdatum, lower(vorname)'.freeze
  BEFORE = "'cancelled_by_participant', 'cancelled_by_organizer', 'pending_email'".freeze

  def up
    replace_indexes("status NOT IN (#{BEFORE}, 'declined_by_club')")
  end

  def down
    replace_indexes("status NOT IN (#{BEFORE})")
  end

  private

  def replace_indexes(active)
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_referee'
    add_index :referee_course_registrations, %i[referee_course_id referee_id], unique: true,
                                                                              where: "referee_id IS NOT NULL AND #{active}",
                                                                              name: 'idx_course_registrations_unique_referee'
    remove_index :referee_course_registrations, name: 'idx_course_registrations_unique_person'
    add_index :referee_course_registrations, PERSON_COLUMNS, unique: true, where: "email IS NOT NULL AND #{active}",
                                                             name: 'idx_course_registrations_unique_person'
  end
end
