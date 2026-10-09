# Nie bestaetigte Anmeldungen (pending_email) sperren keine weitere Anmeldung
# derselben Person mehr. Vorher blockierte eine liegengebliebene oder von
# Fremden ausgeloeste oeffentliche Anmeldung die Person bis zum Loeschlauf.
class PendingEmailDoesNotBlockRegistration < ActiveRecord::Migration[7.2]
  PERSON_COLUMNS = 'referee_course_id, lower(email), geburtsdatum, lower(vorname)'.freeze
  CANCELLED = "'cancelled_by_participant', 'cancelled_by_organizer'".freeze

  def up
    replace_indexes("status NOT IN (#{CANCELLED}, 'pending_email')")
  end

  def down
    replace_indexes("status NOT IN (#{CANCELLED})")
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
