# Ein Schiedsrichterkurs, angelegt von der RSK eines Landesverbands (oder
# bundesweit von FD-RSK/Admin). Loest den CSV-Import der Kursergebnisse ab.
#
# Ein Kurs kann zu mehreren Lizenzstufen fuehren (F-Kurs: L2 oder L1), die
# Person nennt bei der Anmeldung ihr Ziel, die RSK legt beim Abschluss die
# erreichte Stufe fest.
class RefereeCourse < ApplicationRecord
  COURSE_TYPES = %w[j g f combined module refresher n a retest other].freeze
  FORMATS = %w[in_person online hybrid].freeze
  SESSION_FORMATS = %w[in_person online].freeze
  REGISTRATION_MODES = %w[open none].freeze
  # draft: nur fuer die Verwaltung sichtbar. published: Anmeldung moeglich (im
  # Rahmen der Fristen). registration_closed: von Hand geschlossen. held: Kurs
  # gelaufen, Ergebnisse werden erfasst. results_submitted: Lizenzen vergeben.
  STATUSES = %w[draft published registration_closed held results_submitted cancelled].freeze
  # Statusuebergaenge, die die Verwaltung von Hand ausloesen darf. Der Weg nach
  # results_submitted laeuft ueber das Einreichen der Ergebnisse (Paket 4).
  TRANSITIONS = {
    'draft' => %w[published cancelled],
    'published' => %w[registration_closed held cancelled draft],
    'registration_closed' => %w[published held cancelled],
    'held' => %w[registration_closed],
    'results_submitted' => [],
    'cancelled' => %w[draft]
  }.freeze

  belongs_to :state_association, optional: true
  belongs_to :hosting_club, class_name: 'Club', optional: true
  belongs_to :prerequisite_course, class_name: 'RefereeCourse', optional: true
  belongs_to :created_by_user, class_name: 'User', optional: true

  has_many :leads, class_name: 'RefereeCourseLead', dependent: :destroy
  has_many :lead_users, through: :leads, source: :user
  has_many :fields, -> { order(:position, :id) }, class_name: 'RefereeCourseField', dependent: :destroy
  has_many :registrations, class_name: 'RefereeCourseRegistration', dependent: :restrict_with_error
  has_many :referee_course_results, dependent: :nullify

  validates :title, presence: true
  validates :course_type, inclusion: { in: COURSE_TYPES }
  validates :format, inclusion: { in: FORMATS }
  validates :registration_mode, inclusion: { in: REGISTRATION_MODES }
  validates :status, inclusion: { in: STATUSES }
  validates :min_participants, :max_participants, :min_age,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :fee_member_cents, :fee_non_member_cents,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :sessions_shape
  validate :participant_bounds
  validate :deadlines_order
  validate :license_levels_exist
  validate :bundesweite_rechnung_nur_ohne_lv
  validate :status_transition, if: :status_changed?, on: :update
  validate :initial_status, on: :create
  validate :prerequisite_not_self

  before_validation :normalize_arrays
  before_validation :derive_dates_from_sessions

  scope :ordered, -> { order(Arel.sql('starts_on NULLS LAST'), :id) }
  scope :not_cancelled, -> { where.not(status: 'cancelled') }

  # Alle LV, die den Kurs verwalten. Leer bei einem bundesweiten Kurs ohne
  # Partner.
  def managing_state_association_ids
    ([state_association_id] + Array(partner_state_association_ids)).compact.uniq
  end

  def national?
    state_association_id.nil?
  end

  # Ob der Schalter „Kurse im System" fuer diesen Kurs an ist. Ein Kurs mit
  # Partner-LV ist an, sobald einer der beteiligten LV freigeschaltet ist.
  def process_enabled?
    return Setting.referee_courses_enabled? if national?

    managing_state_association_ids.any? { |sa_id| Setting.referee_courses_enabled?(sa_id) }
  end

  def license_levels
    RefereeLicenseLevel.where(id: license_level_ids).ordered
  end

  # Belegte Plaetze: alles, was einen Platz haelt oder gehalten hat.
  def taken_seats
    registrations.where(status: RefereeCourseRegistration::SEAT_STATUSES).count
  end

  def free_seats
    return nil if max_participants.nil?

    [max_participants - taken_seats, 0].max
  end

  def editable?
    %w[draft published registration_closed held].include?(status)
  end

  def summary_hash
    {
      id: id,
      title: title,
      course_type: course_type,
      format: format,
      status: status,
      registration_mode: registration_mode,
      state_association: state_association && { id: state_association.id, name: state_association.name },
      partner_state_association_ids: partner_state_association_ids,
      starts_on: starts_on,
      ends_on: ends_on,
      min_participants: min_participants,
      max_participants: max_participants,
      registration_deadline: registration_deadline,
      public: public,
      license_level_ids: license_level_ids
    }
  end

  # Kurse, fuer die sich Personen anmelden oder die angekuendigt werden:
  # veroeffentlicht oder mit geschlossener Anmeldung, noch nicht vorbei.
  scope :upcoming_offers, lambda {
    where(status: %w[published registration_closed])
      .where('ends_on IS NULL OR ends_on >= ?', Time.zone.today)
  }

  # Darstellung fuer Anmeldende (Portal, Verein, oeffentliche Seite). Ohne
  # Online-Link: Den bekommen nur Angemeldete per Mail. Ohne Teilnehmerliste.
  def offer_hash(levels_by_id: nil)
    levels_by_id ||= RefereeLicenseLevel.where(id: license_level_ids).index_by(&:id)
    {
      id: id,
      title: title,
      course_type: course_type,
      format: format,
      status: status,
      registration_mode: registration_mode,
      state_association: state_association && { id: state_association.id, name: state_association.name },
      partner_state_association_ids: partner_state_association_ids,
      hosting_club: hosting_club && { id: hosting_club.id, name: hosting_club.name },
      starts_on: starts_on,
      ends_on: ends_on,
      sessions: Array(sessions).map { |s| s.except('online_url') },
      online_platform: online_platform,
      min_participants: min_participants,
      max_participants: max_participants,
      free_seats: free_seats,
      registration_opens_at: registration_opens_at,
      registration_deadline: registration_deadline,
      cancellation_deadline: cancellation_deadline,
      registration_closed_reason: RefereeCourseRegistrar.new(self).closed_reason,
      min_age: min_age,
      fee_member_cents: fee_member_cents,
      fee_non_member_cents: fee_non_member_cents,
      fee_only_on_license: fee_only_on_license,
      fee_note: fee_note,
      prerequisites_note: prerequisites_note,
      contact_email: contact_email,
      description: description,
      license_levels: license_level_ids.filter_map { |lid| levels_by_id[lid] }.map { |l| { id: l.id, name: l.name } },
      fields: fields.select { |f| f.archived_at.nil? }.map(&:definition_hash)
    }
  end

  private

  def normalize_arrays
    self.license_level_ids = Array(license_level_ids).compact_blank.map(&:to_i).uniq
    self.partner_state_association_ids =
      Array(partner_state_association_ids).compact_blank.map(&:to_i).uniq - [state_association_id].compact
    self.sessions = Array(sessions).map { |s| s.respond_to?(:to_h) ? s.to_h.stringify_keys : s }
  end

  def derive_dates_from_sessions
    starts = Array(sessions).filter_map { |s| parse_time(s.is_a?(Hash) ? s['starts_at'] : nil) }
    ends = Array(sessions).filter_map { |s| parse_time(s.is_a?(Hash) ? (s['ends_at'].presence || s['starts_at']) : nil) }
    self.starts_on = starts.min&.in_time_zone('Europe/Berlin')&.to_date
    self.ends_on = ends.max&.in_time_zone('Europe/Berlin')&.to_date
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def sessions_shape
    Array(sessions).each_with_index do |session, i|
      unless session.is_a?(Hash)
        errors.add(:sessions, "Termin #{i + 1} ist ungültig")
        next
      end
      starts_at = parse_time(session['starts_at'])
      errors.add(:sessions, "Termin #{i + 1}: Beginn fehlt oder ist ungültig") if starts_at.nil?
      if session['ends_at'].present?
        ends_at = parse_time(session['ends_at'])
        if ends_at.nil? || (starts_at && ends_at < starts_at)
          errors.add(:sessions, "Termin #{i + 1}: Ende liegt vor dem Beginn oder ist ungültig")
        end
      end
      session_format = session['format'].presence || (format == 'online' ? 'online' : 'in_person')
      unless SESSION_FORMATS.include?(session_format)
        errors.add(:sessions, "Termin #{i + 1}: unbekanntes Format")
      end
    end
  end

  def participant_bounds
    return if min_participants.nil? || max_participants.nil?
    return if min_participants <= max_participants

    errors.add(:min_participants, 'darf nicht größer als die Höchstzahl sein')
  end

  def deadlines_order
    return unless registration_opens_at && registration_deadline && registration_opens_at > registration_deadline

    errors.add(:registration_deadline, 'liegt vor dem Anmeldebeginn')
  end

  def license_levels_exist
    return if license_level_ids.blank?

    missing = license_level_ids - RefereeLicenseLevel.where(id: license_level_ids).pluck(:id)
    errors.add(:license_level_ids, "unbekannte Lizenzstufe #{missing.join(', ')}") if missing.any?
  end

  def bundesweite_rechnung_nur_ohne_lv
    return unless bill_state_association && !national?

    errors.add(:bill_state_association, 'gibt es nur bei bundesweiten Kursen')
  end

  def status_transition
    from = status_was
    return if TRANSITIONS.fetch(from, []).include?(status)

    errors.add(:status, "Wechsel von #{from} nach #{status} ist nicht möglich")
  end

  # „Ergebnisse eingereicht" entsteht nur ueber RefereeCourseSubmission, auch
  # nicht beim Anlegen. (Die Verwaltung legt ohnehin nur Entwuerfe an; Tests und
  # Konsole duerfen andere Startzustaende setzen.)
  def initial_status
    return unless status == 'results_submitted'

    errors.add(:status, 'Ergebnisse lassen sich nur über das Einreichen übermitteln')
  end

  def prerequisite_not_self
    return unless prerequisite_course_id.present? && prerequisite_course_id == id

    errors.add(:prerequisite_course_id, 'kann nicht der Kurs selbst sein')
  end
end
