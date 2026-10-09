# Anmeldung einer Person zu einem Schiedsrichterkurs.
#
# Personendaten stehen als Schnappschuss an der Anmeldung, weil eine neue Person
# noch keinen Referee-Datensatz hat: der entsteht erst beim Bestehen ueber den
# RefereeCourseResultApplier. `referee_id` ist gesetzt, sobald die Person einem
# Bestandsschiri zugeordnet ist (Konto, Lizenznummer+Geburtsdatum oder Wahl der
# RSK).
class RefereeCourseRegistration < ApplicationRecord
  # pending_email / pending_guardian: wartet auf Bestaetigung, haelt keinen Platz.
  STATUSES = %w[pending_email pending_guardian registered waitlisted
                cancelled_by_participant cancelled_by_organizer attended no_show].freeze
  # Diese Zustaende belegen einen Platz.
  SEAT_STATUSES = %w[registered attended no_show].freeze
  CANCELLED_STATUSES = %w[cancelled_by_participant cancelled_by_organizer].freeze
  RESULTS = %w[passed failed].freeze
  IDENTITY_MATCHES = %w[account confirmed_existing new_person needs_review].freeze

  belongs_to :referee_course
  belongs_to :referee, optional: true
  belongs_to :user, optional: true
  belongs_to :club, optional: true
  belongs_to :billing_club, class_name: 'Club', optional: true
  belongs_to :desired_license_level, class_name: 'RefereeLicenseLevel', optional: true
  belongs_to :awarded_license_level, class_name: 'RefereeLicenseLevel', optional: true
  belongs_to :registered_by_user, class_name: 'User', optional: true

  # Von der Verwaltung von Hand eingetragen: Pflicht-Zusatzfelder duerfen dann
  # leer bleiben, die RSK kennt die Antworten oft nicht.
  attr_accessor :skip_required_answers

  before_validation :normalize
  before_validation :default_billing_club

  validates :vorname, :nachname, :geburtsdatum, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validates :result, inclusion: { in: RESULTS }, allow_nil: true
  validates :identity_match, inclusion: { in: IDENTITY_MATCHES }
  validates :referee_id, uniqueness: { scope: :referee_course_id, message: 'ist bereits angemeldet' },
                         allow_nil: true
  validates :points, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :unique_person_without_referee
  validate :license_levels_belong_to_course
  validate :custom_answers_match_fields
  validate :billing_address_without_club

  scope :active, -> { where.not(status: CANCELLED_STATUSES) }
  scope :seated, -> { where(status: SEAT_STATUSES) }

  def cancelled?
    CANCELLED_STATUSES.include?(status)
  end

  # Abmeldung nach der Abmeldefrist: Die Gebuehr bleibt faellig.
  def late_cancellation?
    cancelled? && cancelled_at.present? && referee_course.cancellation_deadline.present? &&
      cancelled_at > referee_course.cancellation_deadline
  end

  def age_on(date)
    return nil if geburtsdatum.nil? || date.nil?

    age = date.year - geburtsdatum.year
    age -= 1 if date < geburtsdatum + age.years
    age
  end

  def age_at_course
    age_on(referee_course.starts_on || Date.current)
  end

  # Mitglied im Sinne der Gebuehr: Verein in einem der verwaltenden LV des
  # Kurses (bei bundesweiten Kursen: jeder Verein).
  def member_rate?
    return false if club.nil?
    return true if referee_course.national?

    sa_ids = referee_course.managing_state_association_ids
    StateAssociation.ids_under(sa_ids).include?(club.state_association_id)
  end

  def fee_cents
    course = referee_course
    member = course.fee_member_cents
    non_member = course.fee_non_member_cents.nil? ? member : course.fee_non_member_cents
    member_rate? ? member : non_member
  end

  private

  def normalize
    %w[vorname nachname email telefon stated_lizenznummer guardian_name guardian_email].each do |attr|
      value = self[attr]
      self[attr] = value.is_a?(String) ? value.strip.presence : value
    end
    self.email = email&.downcase
    self.guardian_email = guardian_email&.downcase
    self.custom_answers = {} unless custom_answers.is_a?(Hash)
  end

  def default_billing_club
    self.billing_club_id ||= club_id if new_record?
  end

  # Spiegelt den Unique-Index (Kurs, E-Mail, Geburtsdatum, Vorname), damit die
  # Doppelung als Meldung und nicht als 500 ankommt.
  def unique_person_without_referee
    return if email.blank? || geburtsdatum.blank? || vorname.blank?

    scope = RefereeCourseRegistration.where(referee_course_id: referee_course_id, geburtsdatum: geburtsdatum)
                                     .where('lower(email) = ? AND lower(vorname) = ?', email.downcase, vorname.downcase)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:base, 'Diese Person ist bereits angemeldet') if scope.exists?
  end

  def license_levels_belong_to_course
    allowed = Array(referee_course&.license_level_ids)
    { desired_license_level_id: desired_license_level_id,
      awarded_license_level_id: awarded_license_level_id }.each do |attr, value|
      next if value.nil? || allowed.include?(value)

      errors.add(attr, 'gehört nicht zu den Lizenzstufen des Kurses')
    end
  end

  def custom_answers_match_fields
    return if referee_course.nil?

    fields = referee_course.fields.active.index_by { |f| f.id.to_s }
    # Unbekannte Schluessel (z. B. archivierte oder fremde Felder) verwerfen,
    # vorhandene Antworten archivierter Felder aber behalten.
    archived_ids = referee_course.fields.where.not(archived_at: nil).pluck(:id).map(&:to_s)
    self.custom_answers = custom_answers.slice(*(fields.keys + archived_ids))

    # Pflichtfelder nur pruefen, wenn die Antworten gesetzt werden. Ein spaeter
    # ergaenztes Pflichtfeld soll alte Anmeldungen nicht unspeicherbar machen.
    check_required = !skip_required_answers && (new_record? || custom_answers_changed?)
    fields.each do |key, field|
      value = custom_answers[key]
      if blank_answer?(value)
        custom_answers.delete(key)
        errors.add(:custom_answers, "„#{field.label}“ ist ein Pflichtfeld") if field.required && check_required
        next
      end
      message = answer_error(field, value)
      if message.nil? && field.required && check_required && field.field_type == 'checkbox' && value == false
        message = 'muss bestätigt werden'
      end
      errors.add(:custom_answers, "„#{field.label}“: #{message}") if message
    end
  end

  def blank_answer?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  def answer_error(field, value)
    case field.field_type
    when 'text', 'textarea'
      return 'muss Text sein' unless value.is_a?(String)
      return 'ist zu lang' if value.length > 2000
    when 'select'
      return 'ist keine der Auswahlmöglichkeiten' unless field.options.include?(value)
    when 'multi_select'
      return 'ist keine der Auswahlmöglichkeiten' unless value.is_a?(Array) && (value - field.options).empty?
    when 'checkbox'
      return 'muss ja oder nein sein' unless [true, false].include?(value)
    when 'number'
      return 'muss eine Zahl sein' unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+([.,]\d+)?\z/)
    when 'date'
      Date.iso8601(value.to_s)
    end
    nil
  rescue Date::Error
    'muss ein Datum sein'
  end

  def billing_address_without_club
    return if billing_address.blank? || club_id.nil?

    errors.add(:billing_address, 'gibt es nur ohne Verein; die Rechnung geht an den Verein')
  end
end
