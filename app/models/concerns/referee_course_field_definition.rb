# Gemeinsame Regeln fuer Zusatzfelder einer Kursanmeldung: die Vorlage je LV
# (RefereeCourseFieldTemplate) und das Feld am Kurs (RefereeCourseField).
module RefereeCourseFieldDefinition
  extend ActiveSupport::Concern

  FIELD_TYPES = %w[text textarea select multi_select checkbox number date].freeze
  CHOICE_TYPES = %w[select multi_select].freeze
  # Die Felddefinition wird 1:1 von der Vorlage an den Kurs kopiert.
  COPIED_ATTRIBUTES = %w[label field_type options required position help_text
                         visible_to_lead include_in_billing_export].freeze

  included do
    before_validation :normalize_options

    validates :label, presence: true, length: { maximum: 200 }
    validates :field_type, inclusion: { in: FIELD_TYPES }
    validates :help_text, length: { maximum: 500 }
    validate :options_for_choice_types
  end

  def choice_type?
    CHOICE_TYPES.include?(field_type)
  end

  def definition_hash
    {
      id: id,
      label: label,
      field_type: field_type,
      options: options,
      required: required,
      position: position,
      help_text: help_text,
      visible_to_lead: visible_to_lead,
      include_in_billing_export: include_in_billing_export
    }
  end

  private

  def normalize_options
    self.options = choice_type? ? Array(options).map { |o| o.to_s.strip }.compact_blank.uniq : []
  end

  def options_for_choice_types
    return unless choice_type? && options.size < 2

    errors.add(:options, 'braucht mindestens zwei Auswahlmöglichkeiten')
  end
end
