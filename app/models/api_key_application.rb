# Antrag Außenstehender auf einen API-Zugang. Gestellt über das öffentliche
# Formular (/api-zugang) ohne Benutzerkonto, entschieden von der Administration
# in der Key-Verwaltung.
#
# Zwei Besonderheiten:
#
# 1. Kommerzielle Vorhaben werden hier nicht beantragt. Das Formular führt sie
#    zur individuellen Abstimmung per E-Mail; die Validierung unten stellt
#    sicher, dass auch ein Direktaufruf der API diesen Weg nicht umgeht.
# 2. Der API-Key entsteht erst, wenn der Antragsteller ihn über den Einmal-Link
#    abholt, nicht bei der Genehmigung. ApiKey speichert nur den Digest, der
#    Klartext existiert genau einmal (ApiKey.generate). Ein späteres Anzeigen
#    setzte sonst voraus, den Klartext in der Datenbank zu parken, was dem Zweck
#    des Digests widerspricht. Nebeneffekt: Ein nie abgeholter Zugang
#    hinterlässt keinen aktiven Key.
class ApiKeyApplication < ApplicationRecord
  has_paper_trail

  STATUSES = %w[pending approved rejected].freeze

  # Frist zum Abholen des Keys, analog zur Bestätigungsfrist bei Transfers.
  # Danach stellt die Administration einen neuen Link aus.
  REVEAL_EXPIRES_AFTER_DAYS = 14

  COMMERCIAL_HINT = 'Für kommerzielle Vorhaben ist eine individuelle Absprache nötig. ' \
                    'Bitte wende dich per E-Mail an it@floorball.de.'.freeze

  belongs_to :api_key, optional: true

  before_validation :normalize_email

  validates :status, inclusion: { in: STATUSES }
  validates :organisation, :contact_name, :project_description, :purpose, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP, message: 'ist ungültig' }
  validates :terms_version, presence: true
  validates :accepted_terms_at, presence: true
  validate :must_not_be_commercial
  validate :no_open_request, on: :create

  scope :pending, -> { where(status: 'pending') }

  def self.find_by_reveal_token(token)
    return nil if token.blank?

    find_by(reveal_token_digest: Digest::SHA256.hexdigest(token))
  end

  def pending?
    status == 'pending'
  end

  def approved?
    status == 'approved'
  end

  # Genehmigt den Antrag und stellt den Abhol-Link aus. Gibt das Klartext-Token
  # für den Mailer zurück, oder false, wenn der Antrag zwischenzeitlich (etwa im
  # Parallel-Tab) schon entschieden wurde.
  def approve!(user_id, note = nil)
    token = nil
    self.class.transaction do
      lock!
      return false unless pending?

      token = assign_reveal_token
      self.status = 'approved'
      self.decision_note = note.presence
      self.decided_by = user_id
      self.decided_at = Time.current
      save!
    end
    token
  end

  def reject!(user_id, note)
    return false if note.to_s.strip.blank?

    self.class.transaction do
      lock!
      return false unless pending?

      update!(status: 'rejected', decision_note: note.to_s.strip,
              decided_by: user_id, decided_at: Time.current)
    end
    true
  end

  # Neuer Abhol-Link, wenn der alte abgelaufen ist oder nicht angekommen ist.
  # Ein bereits abgeholter Key wird nicht neu ausgegeben, sonst entstünde ein
  # zweiter Key zum selben Antrag.
  def issue_new_reveal_token!
    return false unless approved? && key_revealed_at.nil?

    token = nil
    self.class.transaction do
      lock!
      token = assign_reveal_token
      save!
    end
    token
  end

  # Zustand des Abhol-Links, ohne ihn zu verbrauchen. Mail-Scanner rufen Links
  # vorab ab, deshalb darf erst der bewusste zweite Schritt den Key erzeugen.
  def reveal_state
    return 'invalid' unless approved? && reveal_token_digest.present?
    return 'already_revealed' if key_revealed_at.present?
    return 'expired' if reveal_token_expires_at.nil? || reveal_token_expires_at.past?

    'valid'
  end

  # Erzeugt den Key und gibt ihn im Klartext zurück, genau einmal. Danach ist
  # nur noch der Digest im ApiKey gespeichert.
  #
  # Der Key startet mit der Standardgrenze aus § 6.1 der Nutzungsvereinbarung.
  # Ohne sie wäre ein bewilligter Zugang unbegrenzt (rate_limit nil überspringt
  # den Throttle) – die Administration kann ihn in der Key-Verwaltung jederzeit
  # anheben oder aufheben.
  def reveal_key!
    raw_key = nil
    self.class.transaction do
      lock!
      return nil unless reveal_state == 'valid'

      raw_key, key = ApiKey.generate(name: key_name, rate_limit: ApiTerms::RATE_LIMIT_PER_MINUTE)
      return nil if raw_key.blank? || !key.persisted?

      update!(api_key: key, key_revealed_at: Time.current)
    end
    raw_key
  end

  def as_json(*)
    {
      id:,
      organisation:,
      contact_name:,
      email:,
      address:,
      project_description:,
      purpose:,
      project_url:,
      commercial:,
      status:,
      terms_version:,
      accepted_terms_at: accepted_terms_at&.iso8601,
      decision_note:,
      decided_at: decided_at&.iso8601,
      api_key_id:,
      reveal_state: approved? ? reveal_state : nil,
      reveal_token_expires_at: reveal_token_expires_at&.iso8601,
      key_revealed_at: key_revealed_at&.iso8601,
      created_at: created_at&.iso8601
    }
  end

  private

  # Der Key-Name muss den Antrag wiedererkennbar machen: Die Key-Liste zeigt ihn
  # neben manuell angelegten Keys.
  def key_name
    "#{organisation} (Antrag ##{id})"
  end

  def assign_reveal_token
    token = SecureRandom.urlsafe_base64(32)
    self.reveal_token_digest = Digest::SHA256.hexdigest(token)
    self.reveal_token_expires_at = REVEAL_EXPIRES_AFTER_DAYS.days.from_now
    token
  end

  def normalize_email
    self.email = email.to_s.strip.downcase
  end

  def must_not_be_commercial
    return unless commercial

    errors.add(:base, COMMERCIAL_HINT)
  end

  def no_open_request
    return if email.blank? || organisation.blank?
    return unless self.class.pending.where(email:, organisation:).exists?

    errors.add(:base, 'Für diese Adresse liegt bereits ein offener Antrag vor. ' \
                      'Bitte warte die Entscheidung ab.')
  end
end
