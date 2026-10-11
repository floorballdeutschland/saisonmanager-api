# Anmelden, Abmelden und Nachruecken bei Schiedsrichterkursen, gemeinsam fuer
# Schiri-Portal, Vereinsanmeldung und (spaeter) das oeffentliche Formular. Die
# Verwaltung (Admin::RefereeCourseRegistrationsController) traegt weiter direkt
# ein, nutzt aber das Nachruecken.
#
# Regeln:
# - Anmelden nur, solange der Kurs veroeffentlicht ist, die Anmeldung im System
#   laeuft und das Fenster offen ist (registration_opens_at bis
#   registration_deadline).
# - Mindestalter am ersten Kurstag (RefereeCourseRegistration#age_at_course).
# - Unter GUARDIAN_AGE braucht eine neue Person (ohne Schiri-Datensatz) die
#   Einwilligung der Erziehungsberechtigten: Die Anmeldung steht auf
#   `pending_guardian`, haelt keinen Platz und wird erst mit der Bestaetigung
#   eingeplant. Bestandsschiris sind ueber ihren Verein schon im System.
# - Ist der Kurs voll, landet die Anmeldung auf der Warteliste. Wird ein Platz
#   frei, rueckt die aelteste Wartelisten-Anmeldung nach (#promote_waitlist).
class RefereeCourseRegistrar
  GUARDIAN_AGE = 16
  GUARDIAN_TOKEN_VALIDITY = 14.days

  Error = Class.new(StandardError)

  # Kurse, fuer die eine Anmeldung noch bestaetigt werden kann.
  OPEN_COURSE_STATUSES = %w[published registration_closed].freeze

  Result = Struct.new(:registration, :error, :guardian_token, keyword_init: true) do
    def success?
      error.nil?
    end
  end

  def initialize(course)
    @course = course
  end

  # Ob gerade angemeldet werden kann; nil oder der Grund.
  def closed_reason(now: Time.current)
    return 'Für diesen Kurs gibt es keine Anmeldung im System' if @course.registration_mode != 'open'
    return 'Die Anmeldung ist nicht geöffnet' unless @course.status == 'published'
    if @course.registration_opens_at && now < @course.registration_opens_at
      return "Die Anmeldung beginnt erst am #{@course.registration_opens_at.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M')}"
    end
    return 'Der Anmeldeschluss ist vorbei' if @course.registration_deadline && now > @course.registration_deadline

    nil
  end

  # attrs: Personendaten und Antworten (siehe RefereeCourseRegistration).
  # source: 'portal', 'club' oder 'public'.
  def register(attrs, source:, registered_by: nil)
    reason = closed_reason
    return Result.new(error: reason) if reason

    registration = nil
    guardian_token = nil
    RefereeCourse.transaction do
      # Sperre auf dem Kurs: Zwei gleichzeitige Anmeldungen duerfen nicht beide
      # den letzten Platz bekommen.
      @course.lock!
      registration = @course.registrations.new(attrs.merge(source: source, registered_by_user: registered_by))
      error = age_error(registration)
      raise Error, error if error

      if needs_guardian?(registration)
        raise Error, 'Für Personen unter 16 braucht es Name und E-Mail der Erziehungsberechtigten' if
          registration.guardian_name.blank? || registration.guardian_email.blank?

        guardian_token = SecureRandom.urlsafe_base64(32)
        registration.assign_attributes(status: 'pending_guardian',
                                       guardian_token_digest: digest(guardian_token),
                                       guardian_token_expires_at: guardian_token_expiry)
      else
        registration.status = seat_available? ? 'registered' : 'waitlisted'
      end
      registration.save!
    end
    notify_registered(registration, guardian_token)
    Result.new(registration: registration, guardian_token: guardian_token)
  rescue Error => e
    Result.new(error: e.message)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(error: e.record.errors.full_messages.to_sentence)
  end

  # Abmeldung durch die Person selbst oder ihren Verein. Nach der Abmeldefrist
  # geht es weiter, die Gebuehr bleibt aber faellig (late_cancellation?).
  def cancel(registration, by_organizer: false)
    return Result.new(error: 'Die Anmeldung ist bereits abgemeldet') if registration.cancelled?
    return Result.new(error: 'Der Kurs hat schon stattgefunden') unless @course.editable? && @course.status != 'held'

    was_seated = RefereeCourseRegistration::SEAT_STATUSES.include?(registration.status)
    registration.skip_required_answers = true
    registration.update!(status: by_organizer ? 'cancelled_by_organizer' : 'cancelled_by_participant',
                         cancelled_at: Time.current, guardian_token_digest: nil)
    RefereeCourseMailer.cancelled(registration).deliver_later if RefereeCourseMailer.recipient(registration)
    promote_waitlist if was_seated
    Result.new(registration: registration)
  end

  # Einwilligung der Erziehungsberechtigten. Danach regulaer einplanen.
  def self.confirm_guardian(raw_token)
    registration = find_by_guardian_token(raw_token)
    return Result.new(error: 'Der Link ist ungültig oder abgelaufen') if registration.nil?

    registrar = new(registration.referee_course)
    RefereeCourse.transaction do
      registration.referee_course.lock!
      registration.skip_required_answers = true
      registration.update!(status: registrar.seat_available? ? 'registered' : 'waitlisted',
                           guardian_confirmed_at: Time.current,
                           guardian_token_digest: nil)
    end
    registrar.notify_registered(registration, nil)
    Result.new(registration: registration)
  end

  # Nur fuer Kurse, die noch bevorstehen: Nach einer Absage oder Durchfuehrung
  # darf ein alter Link niemanden mehr einplanen.
  def self.find_by_guardian_token(raw_token)
    return nil if raw_token.blank?

    RefereeCourseRegistration.where(status: 'pending_guardian')
                             .where('guardian_token_expires_at IS NULL OR guardian_token_expires_at > ?', Time.current)
                             .joins(:referee_course)
                             .where(referee_courses: { status: OPEN_COURSE_STATUSES })
                             .find_by(guardian_token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  # Freie Plaetze an die Warteliste vergeben, aelteste Anmeldung zuerst. Laeuft
  # nach jeder Abmeldung und wenn die Verwaltung die Hoechstzahl anhebt oder
  # einen Status aendert. Nur fuer Kurse, die noch bevorstehen.
  def promote_waitlist
    return [] unless %w[published registration_closed].include?(@course.status)

    promoted = []
    RefereeCourse.transaction do
      @course.lock!
      while seat_available?
        next_up = @course.registrations.where(status: 'waitlisted').order(:created_at, :id).first
        break if next_up.nil?

        next_up.skip_required_answers = true
        next_up.update!(status: 'registered')
        promoted << next_up
      end
    end
    promoted.each { |r| RefereeCourseMailer.promoted(r).deliver_later if RefereeCourseMailer.recipient(r) }
    promoted
  end

  def seat_available?
    @course.max_participants.nil? || @course.registrations.seated.count < @course.max_participants
  end

  def notify_registered(registration, guardian_token)
    if guardian_token
      RefereeCourseMailer.guardian_consent(registration, guardian_token).deliver_later
    elsif RefereeCourseMailer.recipient(registration)
      RefereeCourseMailer.registered(registration).deliver_later
    end
  rescue StandardError => e
    Rails.logger.warn("RefereeCourseRegistrar: Mail fuer Anmeldung #{registration.id} fehlgeschlagen: #{e.message}")
  end

  private

  def age_error(registration)
    return nil if @course.min_age.nil? || registration.geburtsdatum.nil?

    age = registration.age_at_course
    "Mindestalter für diesen Kurs: #{@course.min_age} Jahre" if age && age < @course.min_age
  end

  def needs_guardian?(registration)
    return false if registration.referee_id.present?

    age = registration.age_at_course
    age.present? && age < GUARDIAN_AGE
  end

  def guardian_token_expiry
    [Time.current + GUARDIAN_TOKEN_VALIDITY, @course.registration_deadline].compact.min
  end

  def digest(raw)
    Digest::SHA256.hexdigest(raw)
  end
end
