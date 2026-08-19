# Katalog der Dokumentarten für Lizenz-Pflichtdokumente. game_operation_id =
# nil bedeutet global (bundesweit), sonst verbandsspezifisch (vgl. RefereeTag).
# `key` ist der stabile, technische Bezeichner: Ligen referenzieren Dokumentarten
# über required_documents (String-Array von Keys), Uploads über
# license_documents.document_type. `validity`: 'once' = einmal je Spieler,
# gilt für immer; 'per_season' = muss je Saison neu vorliegen.
# Altersregel, zwei Formen, die sich ausschließen; beide leer = immer
# erforderlich:
# `required_below_age`: nur erforderlich, wenn der Spieler am Tag der
# Lizenzbeantragung jünger ist (z. B. 18 = Zustimmung Erziehungsberechtigte,
# 16 = Sportärztliches Attest). Tagesgenauer Stichtag.
# `required_from_birth_year`: erforderlich für alle, die im angegebenen Jahr oder
# später geboren sind (z. B. 2012 = „ab Jahrgang 2012"). Gilt für den ganzen
# Jahrgang, unabhängig von Geburtstag und Antragsdatum — dafür muss ein fester
# Jahrgang jede Saison nachgezogen werden (bewusst so, entspricht dem Denken der
# Vereine; die mitwandernde Variante „Alter zum 31.12. der Saison" ist
# zurückgestellt, siehe #483).
class DocumentType < ApplicationRecord
  VALIDITIES = %w[once per_season].freeze

  belongs_to :game_operation, optional: true
  has_one_attached :template

  before_validation :generate_key, on: :create

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :game_operation_id, case_sensitive: false }
  validates :key, presence: true, uniqueness: true
  validates :validity, inclusion: { in: VALIDITIES }
  validates :required_below_age, numericality: { only_integer: true, greater_than: 0, less_than: 100 },
                                 allow_nil: true
  # Untergrenze mit Luft nach unten, Obergrenze das laufende Jahr: Ein Jahrgang in
  # der Zukunft kann niemanden treffen und ist immer ein Tippfehler.
  validates :required_from_birth_year,
            numericality: { only_integer: true, greater_than: 1900,
                            less_than_or_equal_to: ->(_dt) { Date.current.year } },
            allow_nil: true
  validate :single_age_rule
  validate :template_valid, if: -> { template.attached? }

  scope :for_game_operations, lambda { |go_ids|
    where(game_operation_id: go_ids).or(where(game_operation_id: nil))
  }

  ALLOWED_TEMPLATE_CONTENT_TYPES = %w[application/pdf image/png image/jpeg].freeze
  MAX_TEMPLATE_SIZE = 10.megabytes

  # Altersregeln für Keys, die auch ohne Katalog-Eintrag angefordert werden
  # können. `parental_consent` kommt über das Liga-Flag
  # (parental_consent_required) in die Pflichtliste, unabhängig davon, ob die
  # Dokumentart im Katalog steht. Ohne diese Rückfallregel gälte sie dort auch
  # für Volljährige, weil Keys ohne Katalog-Eintrag bewusst immer erforderlich
  # bleiben (Freitext-Altbestand).
  FALLBACK_REQUIRED_BELOW_AGE = { 'parental_consent' => 18 }.freeze

  # Welche der Liga-Keys sind für diesen Spieler tatsächlich erforderlich?
  # Stichtag für Arten mit `required_below_age` ist das Datum der
  # Lizenzbeantragung; Arten mit `required_from_birth_year` sehen es nicht an.
  # Keys ohne Katalogeintrag (Freitext-Altbestand) bleiben erforderlich, ausgenommen
  # die Keys aus FALLBACK_REQUIRED_BELOW_AGE.
  def self.required_keys(keys, birthdate:, requested_at:, catalog: nil)
    keys = Array(keys)
    return [] if keys.empty?

    catalog ||= where(key: keys).index_by(&:key)
    reference = requested_at || Time.current
    keys.select do |k|
      type = catalog[k] || fallback_type(k)
      type.nil? || type.required_for?(birthdate, reference)
    end
  end

  # Nicht gespeicherter Platzhalter, nur zur Altersauswertung. nil für Keys ohne
  # bekannte Regel – die bleiben erforderlich.
  def self.fallback_type(key)
    age = FALLBACK_REQUIRED_BELOW_AGE[key]
    age && new(required_below_age: age)
  end
  private_class_method :fallback_type

  def required_for?(birthdate, requested_at)
    return true if age_rule.nil?

    dob = parse_birthdate(birthdate)
    # Ohne lesbares Geburtsdatum lieber anfordern als still verzichten.
    return true if dob.nil?

    if age_rule == :from_birth_year
      dob.year >= required_from_birth_year
    else
      age_at(dob, requested_at.to_date) < required_below_age
    end
  end

  # Welche der beiden Formen greift? nil = keine, die Art ist immer erforderlich.
  # Die Validierung stellt sicher, dass nie beide gesetzt sind; die Reihenfolge
  # hier entscheidet also nichts, sie macht die Auswertung nur unabhaengig davon.
  def age_rule
    return :from_birth_year if required_from_birth_year.present?
    return :below_age if required_below_age.present?

    nil
  end

  def per_season?
    validity == 'per_season'
  end

  private

  def single_age_rule
    return unless required_below_age.present? && required_from_birth_year.present?

    errors.add(:base, 'Es kann nur eine Altersregel gelten: entweder ein Alter am Stichtag oder ein Geburtsjahrgang.')
  end

  def parse_birthdate(value)
    return value if value.is_a?(Date)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def age_at(birthdate, reference_date)
    age = reference_date.year - birthdate.year
    age -= 1 if reference_date < birthdate + age.years
    age
  end

  def generate_key
    return if key.present? || name.blank?

    base = name.parameterize(separator: '_').tr('-', '_')
    candidate = base
    suffix = 2
    while self.class.exists?(key: candidate)
      candidate = "#{base}_#{suffix}"
      suffix += 1
    end
    self.key = candidate
  end

  def template_valid
    unless template.content_type.in?(ALLOWED_TEMPLATE_CONTENT_TYPES)
      errors.add(:template, 'muss PDF, PNG oder JPEG sein')
    end
    errors.add(:template, 'darf maximal 10 MB groß sein') if template.byte_size > MAX_TEMPLATE_SIZE
  end
end
