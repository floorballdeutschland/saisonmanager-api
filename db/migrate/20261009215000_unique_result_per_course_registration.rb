# Eine Ergebniszeile je Kursanmeldung. Schuetzt zusaetzlich zur Statuspruefung
# in RefereeCourseSubmission gegen doppeltes Einreichen.
class UniqueResultPerCourseRegistration < ActiveRecord::Migration[7.2]
  def change
    remove_index :referee_course_results, :referee_course_registration_id
    add_index :referee_course_results, :referee_course_registration_id, unique: true,
                                                                        where: 'referee_course_registration_id IS NOT NULL'
  end
end
