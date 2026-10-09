require 'csv'

# Teilnehmerliste eines Kurses als CSV: alle Anmeldungen samt Status,
# Kontakt- und Rechnungsangaben und allen Zusatzfeldern (auch archivierten, die
# noch Antworten tragen). Format wie der Rechnungsexport: Semikolon, CRLF,
# UTF-8 mit BOM.
class RefereeCourseParticipantList
  STATUS_LABELS = {
    'pending_email' => 'E-Mail unbestätigt', 'pending_guardian' => 'Einwilligung offen',
    'registered' => 'angemeldet', 'waitlisted' => 'Warteliste',
    'cancelled_by_participant' => 'selbst abgemeldet', 'cancelled_by_organizer' => 'abgemeldet',
    'attended' => 'teilgenommen', 'no_show' => 'nicht erschienen'
  }.freeze

  def initialize(course)
    @course = course
  end

  def to_csv
    fields = @course.fields.to_a
    registrations = @course.registrations.includes(:club, :billing_club, :referee, :desired_license_level)
                           .order(:nachname, :vorname)
    body = CSV.generate(col_sep: ';', row_sep: "\r\n", force_quotes: true) do |csv|
      csv << (headers + fields.map(&:label))
      registrations.each { |reg| csv << (values(reg) + fields.map { |f| answer(reg.custom_answers[f.id.to_s]) }) }
    end
    "\uFEFF#{body}"
  end

  private

  def headers
    ['Nachname', 'Vorname', 'Geburtsdatum', 'Alter am Kurs', 'E-Mail', 'Telefon', 'Verein', 'Lizenznummer',
     'Aktuelle Lizenz', 'Angestrebte Lizenz', 'Status', 'Ergebnis', 'Testversion', 'Punkte',
     'Kostenübernahme', 'Rechnungsanschrift', 'Erziehungsberechtigte', 'Bemerkung', 'Angemeldet am', 'Herkunft']
  end

  def values(reg)
    [
      reg.nachname, reg.vorname, reg.geburtsdatum&.strftime('%d.%m.%Y'), reg.age_at_course, reg.email, reg.telefon,
      reg.club&.name, reg.referee&.lizenznummer || reg.stated_lizenznummer, reg.referee&.lizenzstufe,
      reg.desired_license_level&.name, STATUS_LABELS[reg.status], { 'passed' => 'bestanden', 'failed' => 'nicht bestanden' }[reg.result],
      reg.test_version, reg.points&.to_s&.tr('.', ','), reg.billing_club&.name, reg.billing_address,
      [reg.guardian_name, reg.guardian_email].compact_blank.join(', ').presence, reg.remarks,
      reg.created_at.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M'), reg.source
    ]
  end

  def answer(value)
    case value
    when Array then value.join(', ')
    when true then 'ja'
    when false then 'nein'
    else value
    end
  end
end
