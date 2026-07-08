# Katalog der Dokumentarten für Lizenz-Pflichtdokumente. game_operation_id =
# nil bedeutet global (bundesweit), sonst verbandsspezifisch (vgl. RefereeTag).
# `key` ist der stabile, technische Bezeichner: Ligen referenzieren Dokumentarten
# über required_documents (String-Array von Keys), Uploads über
# license_documents.document_type. `validity`: 'once' = einmal je Spieler,
# gilt für immer; 'per_season' = muss je Saison neu vorliegen.
# `required_below_age`: nur erforderlich, wenn der Spieler am Tag der
# Lizenzbeantragung jünger ist (z. B. 18 = Zustimmung Erziehungsberechtigte,
# 16 = Sportärztliches Attest); nil = immer erforderlich.
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
  validate :template_valid, if: -> { template.attached? }

  scope :for_game_operations, lambda { |go_ids|
    where(game_operation_id: go_ids).or(where(game_operation_id: nil))
  }

  ALLOWED_TEMPLATE_CONTENT_TYPES = %w[application/pdf image/png image/jpeg].freeze
  MAX_TEMPLATE_SIZE = 10.megabytes

  # Welche der Liga-Keys sind für diesen Spieler tatsächlich erforderlich?
  # Stichtag für altersabhängige Dokumente ist das Datum der Lizenzbeantragung.
  # Keys ohne Katalogeintrag (Freitext-Altbestand) bleiben erforderlich.
  def self.required_keys(keys, birthdate:, requested_at:, catalog: nil)
    keys = Array(keys)
    return [] if keys.empty?

    catalog ||= where(key: keys).index_by(&:key)
    reference = requested_at || Time.current
    keys.select { |k| catalog[k].nil? || catalog[k].required_for?(birthdate, reference) }
  end

  def required_for?(birthdate, requested_at)
    return true if required_below_age.blank?

    dob = parse_birthdate(birthdate)
    # Ohne lesbares Geburtsdatum lieber anfordern als still verzichten.
    return true if dob.nil?

    age_at(dob, requested_at.to_date) < required_below_age
  end

  def per_season?
    validity == 'per_season'
  end

  private

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
