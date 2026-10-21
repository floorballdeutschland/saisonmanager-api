# Welche Kursanmeldungen nach der Loeschfrist wegfallen. Ausgelagert aus dem
# Rake-Task, damit die Auswahl getestet werden kann.
class RefereeCourseRegistrationPurge
  RETENTION = 12.months
  UNCONFIRMED_GRACE = 7.days

  def self.scopes
    now = Time.current
    without_results = RefereeCourseRegistration.where.not(
      id: RefereeCourseResult.where.not(referee_course_registration_id: nil).select(:referee_course_registration_id)
    )
    ended = RefereeCourse.where('ends_on < ?', (now - RETENTION).to_date)
                         .or(RefereeCourse.where(status: 'cancelled').where(updated_at: ...(now - RETENTION)))
    # Hat der Verein bis eine Woche nach Kursende nicht entschieden, kommt die
    # Anmeldung nicht mehr zustande.
    past = RefereeCourse.where(ends_on: ...(now - UNCONFIRMED_GRACE).to_date)
    {
      'ohne Schiri, Kurs vor ueber 12 Monaten' =>
        without_results.where(referee_id: nil, referee_course_id: ended.select(:id)),
      'E-Mail nie bestaetigt' =>
        without_results.where(status: 'pending_email')
                       .where(email_confirmation_expires_at: ...(now - UNCONFIRMED_GRACE)),
      'Verein hat nie entschieden, Kurs vorbei' =>
        without_results.where(status: 'pending_club', referee_course_id: past.select(:id)),
      'Einwilligung nie erteilt' =>
        without_results.where(status: 'pending_guardian')
                       .where(guardian_token_expires_at: ...(now - UNCONFIRMED_GRACE))
    }
  end
end
