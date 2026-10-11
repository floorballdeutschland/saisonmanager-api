# Mails rund um die Anmeldung zu Schiedsrichterkursen. Alle Vorlagen sind im
# EmailTemplateCatalog gefuehrt und in der Verwaltung editierbar.
#
# Empfaenger ist die angemeldete Person; ohne eigene Adresse (vom Verein
# angemeldet) die Erziehungsberechtigten, sonst das Konto, das angemeldet hat.
# Antworten gehen an die Kontaktadresse des Kurses.
class RefereeCourseMailer < ApplicationMailer
  def self.recipient(registration)
    registration.email.presence ||
      registration.guardian_email.presence ||
      registration.registered_by_user&.email.presence
  end

  def registered(registration)
    course_mail(registration, waitlisted: registration.status == 'waitlisted')
  end

  def promoted(registration)
    course_mail(registration)
  end

  def cancelled(registration)
    course_mail(registration)
  end

  def course_cancelled(registration)
    course_mail(registration)
  end

  # An die Erziehungsberechtigten: Einwilligung per Link. Erst danach ist die
  # Anmeldung eingeplant.
  def guardian_consent(registration, raw_token)
    setup(registration)
    @link = "#{FrontendUrl.base}/kurs-einwilligung/#{raw_token}"
    @guardian_name = registration.guardian_name
    templated_mail(
      to: registration.guardian_email,
      subject: "Einwilligung zur Anmeldung: #{@course.title}",
      default_reply_to: @course.contact_email.presence,
      placeholders: placeholders.merge(link: @link, guardian_name: @guardian_name.to_s)
    )
  end

  private

  def course_mail(registration, waitlisted: false)
    setup(registration)
    @waitlisted = waitlisted
    templated_mail(
      to: self.class.recipient(registration),
      subject: "#{subject_prefix}: #{@course.title}",
      default_reply_to: @course.contact_email.presence,
      placeholders: placeholders
    )
  end

  def setup(registration)
    @registration = registration
    @course = registration.referee_course
    @name = "#{registration.vorname} #{registration.nachname}"
    @first_name = registration.vorname
    @sessions = Array(@course.sessions).map { |s| session_line(s) }
    @online = Array(@course.sessions).any? { |s| s['online_url'].present? }
    @cancellation_deadline = @course.cancellation_deadline&.in_time_zone('Europe/Berlin')&.strftime('%d.%m.%Y %H:%M')
  end

  def subject_prefix
    {
      'registered' => @waitlisted ? 'Warteliste' : 'Anmeldung bestätigt',
      'promoted' => 'Platz frei geworden',
      'cancelled' => 'Abmeldung bestätigt',
      'course_cancelled' => 'Kurs abgesagt'
    }.fetch(action_name, 'Schiedsrichterkurs')
  end

  def placeholders
    { first_name: @first_name.to_s, name: @name, course_title: @course.title,
      dates: @sessions.join("\n"), cancellation_deadline: @cancellation_deadline.to_s }
  end

  # Ein Termin als Textzeile. Den Online-Link bekommen nur Angemeldete, also nur
  # in diesen Mails und nie auf der oeffentlichen Seite.
  def session_line(session)
    starts = Time.iso8601(session['starts_at'].to_s).in_time_zone('Europe/Berlin')
    line = starts.strftime('%d.%m.%Y %H:%M')
    if session['ends_at'].present?
      line += " bis #{Time.iso8601(session['ends_at'].to_s).in_time_zone('Europe/Berlin').strftime('%H:%M')}"
    end
    place = [session['location'].presence, session['online_url'].presence].compact.join(', ')
    place.present? ? "#{line}, #{place}" : line
  rescue ArgumentError
    session['starts_at'].to_s
  end
end
