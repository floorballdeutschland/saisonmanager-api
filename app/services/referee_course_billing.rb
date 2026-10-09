require 'csv'

# Rechnungsexport der Schiedsrichterkurse fuer einen Landesverband (oder die
# bundesweiten Kurse von FD). Eine Zeile pro abzurechnender Teilnahme; eine
# Person taucht also mehrfach auf, wenn sie mehrere Kurse oder einen Nachtest
# hat (Entscheidung 09.10.2026).
#
# Abgerechnet wird:
# - Teilnahme (attended). Bei „Gebuehr nur bei Lizenzerteilung" erst, wenn FD
#   die Lizenz erteilt hat.
# - Nichterscheinen (no_show), wenn der Kurs das so vorsieht.
# - Abmeldung nach der Abmeldefrist: Die Gebuehr bleibt faellig.
# Nie: abgesagte Kurse, Kurse ohne Gebuehr, bereits abgerechnete Zeilen (ausser
# ausdruecklich include_billed).
#
# Rechnungsempfaenger ist der kostenuebernehmende Verein. Ohne Verein die Person
# mit ihrer Rechnungsanschrift. Bundesweite Kurse mit bill_state_association
# gehen an den Landesverband des Vereins.
class RefereeCourseBilling
  COLUMNS = [
    'Vorname', 'Name', 'Kursdatum', 'Kurstyp', 'Kurstitel', 'Rechnungsempfänger', 'Verein',
    'Vereinsanschrift Straße', 'Vereinsanschrift PLZ', 'Vereinsanschrift Ort', 'Vereins-Kontakt-E-Mail',
    'Rechnungsanschrift (ohne Verein)', 'Betrag', 'Teilnahme', 'Kurs-ID', 'Anmeldungs-ID'
  ].freeze

  COURSE_TYPE_LABELS = {
    'j' => 'J-Kurs', 'g' => 'G-Kurs', 'f' => 'F-Kurs', 'combined' => 'Kombikurs', 'module' => 'Modul',
    'refresher' => 'Fortbildung', 'n' => 'N-Kurs', 'a' => 'A-Kurs', 'retest' => 'Nachtest', 'other' => 'Kurs'
  }.freeze

  Row = Struct.new(:registration, :participation, :amount_cents, :recipient, :warnings, keyword_init: true)

  attr_reader :state_association_id, :from, :to

  # state_association_id nil: bundesweite Kurse.
  def initialize(state_association_id:, from: nil, to: nil, include_billed: false)
    @state_association_id = state_association_id
    @from = from
    @to = to
    @include_billed = include_billed
  end

  def courses
    scope = RefereeCourse.where(state_association_id: @state_association_id)
                         .where(status: %w[held results_submitted])
    scope = scope.where(ends_on: @from..) if @from
    scope = scope.where(ends_on: ..@to) if @to
    scope
  end

  def rows
    @rows ||= begin
      registrations = RefereeCourseRegistration.where(referee_course_id: courses.select(:id))
                                               .includes(:billing_club, :club, referee_course: :fields)
                                               .order(:referee_course_id, :nachname, :vorname)
      registrations = registrations.where(billed_at: nil) unless @include_billed
      licensed = RefereeCourseResult.where(referee_course_registration_id: registrations.map(&:id),
                                           status: 'applied').pluck(:referee_course_registration_id).to_set
      registrations.filter_map { |reg| build_row(reg, licensed) }
    end
  end

  # Teilnahmen, die erst mit der Lizenz abgerechnet werden und noch warten.
  def waiting_for_license
    @waiting_for_license ||= []
  end

  def total_cents
    rows.sum(&:amount_cents)
  end

  def extra_fields
    @extra_fields ||= RefereeCourseField.where(referee_course_id: courses.select(:id), include_in_billing_export: true)
                                        .order(:position, :id).to_a.uniq(&:label)
  end

  def headers
    COLUMNS + extra_fields.map(&:label)
  end

  # Excel fuehrt Zellen, die mit = + - @ (oder Tab/CR) beginnen, als Formel
  # aus. Namen, Anschriften und Freitexte kommen auch aus dem oeffentlichen
  # Formular, deshalb wird solchen Zellen ein Apostroph vorangestellt.
  def self.safe_cell(value)
    return value unless value.is_a?(String) && value.match?(/\A[=+\-@\t\r]/)

    "'#{value}"
  end

  def csv_values(row)
    reg = row.registration
    course = reg.referee_course
    club = reg.billing_club
    answers = extra_fields.map do |field|
      course_field = course.fields.find { |f| f.label == field.label && f.include_in_billing_export }
      format_answer(course_field && reg.custom_answers[course_field.id.to_s])
    end
    [
      reg.vorname, reg.nachname, date(course.ends_on || course.starts_on), COURSE_TYPE_LABELS[course.course_type],
      course.title, row.recipient, club&.long_name.presence || club&.name,
      [club&.street, club&.house_number].compact_blank.join(' '), club&.postcode, club&.city, club&.contact_email,
      club ? nil : reg.billing_address, euro(row.amount_cents), row.participation, course.id, reg.id
    ] + answers
  end

  def to_csv
    body = CSV.generate(col_sep: ';', row_sep: "\r\n", force_quotes: true) do |csv|
      csv << headers
      rows.each { |row| csv << csv_values(row).map { |v| self.class.safe_cell(v) } }
    end
    "\uFEFF#{body}"
  end

  StaleRows = Class.new(StandardError)

  # Erzeugt den Export, haengt die Datei an und markiert die Zeilen als
  # abgerechnet, in einer Transaktion. Die Zeilen werden gesperrt und duerfen
  # noch nicht abgerechnet sein: Zwei gleichzeitige Exporte oder ein Export
  # mit include_billed rechneten sonst dieselben Anmeldungen doppelt ab.
  def create!(user:)
    raise ArgumentError, 'Bereits Abgerechnetes laesst sich nur ansehen, nicht erneut exportieren' if @include_billed

    content = to_csv
    export = nil
    ids = rows.map { |r| r.registration.id }
    RefereeCourseBillingExport.transaction do
      locked = RefereeCourseRegistration.where(id: ids, billed_at: nil).lock.pluck(:id)
      raise StaleRows, 'Inzwischen wurde ein Teil davon abgerechnet. Bitte die Vorschau neu laden.' if
        locked.size != ids.size

      export = RefereeCourseBillingExport.create!(
        state_association_id: @state_association_id, created_by_user: user, from_date: @from, to_date: @to,
        row_count: rows.size, total_cents: total_cents
      )
      export.file.attach(io: StringIO.new(content), filename: filename(export), content_type: 'text/csv')
      RefereeCourseRegistration.where(id: ids).update_all(billed_at: Time.current, billing_export_id: export.id)
    end
    export
  end

  def filename(export = nil)
    lv = StateAssociation.find_by(id: @state_association_id)&.short_name.presence || 'FD'
    "schiri-kurse-abrechnung-#{lv.parameterize}-#{(export&.created_at || Time.current).strftime('%Y-%m-%d')}" \
      "#{"-#{export.id}" if export}.csv"
  end

  private

  def build_row(reg, licensed)
    course = reg.referee_course
    participation = participation_for(reg, course)
    return nil if participation.nil?

    amount = reg.fee_cents
    return nil if amount.nil? || amount.zero?

    if course.fee_only_on_license && participation == 'teilgenommen' && licensed.exclude?(reg.id)
      waiting_for_license << reg
      return nil
    end

    Row.new(registration: reg, participation: participation, amount_cents: amount,
            recipient: recipient_for(reg, course), warnings: warnings_for(reg))
  end

  def participation_for(reg, course)
    return 'teilgenommen' if reg.status == 'attended'
    return 'nicht erschienen' if reg.status == 'no_show' && course.no_show_billable
    return 'spät abgemeldet' if reg.late_cancellation?

    nil
  end

  def recipient_for(reg, course)
    club = reg.billing_club
    if course.bill_state_association && club&.state_association
      root = StateAssociation.find_by(id: StateAssociation.root_id(club.state_association_id))
      return (root || club.state_association).name
    end
    return club.long_name.presence || club.name if club

    "#{reg.vorname} #{reg.nachname} (privat)"
  end

  def warnings_for(reg)
    club = reg.billing_club
    return ['ohne Verein und ohne Rechnungsanschrift'] if club.nil? && reg.billing_address.blank?
    return [] if club.nil?

    warnings = []
    warnings << 'Vereinsanschrift unvollständig' if club.street.blank? || club.postcode.blank? || club.city.blank?
    warnings << 'Verein ohne Kontakt-E-Mail' if club.contact_email.blank?
    warnings
  end

  def date(value)
    value&.strftime('%d.%m.%Y')
  end

  def euro(cents)
    format('%.2f', cents / 100.0).tr('.', ',')
  end

  def format_answer(value)
    case value
    when Array then value.join(', ')
    when true then 'ja'
    when false then 'nein'
    else value
    end
  end
end
