# Zusatzfeld der Anmeldung zu einem Kurs. Antworten stehen in
# RefereeCourseRegistration#custom_answers unter der Feld-id.
#
# Sobald es Anmeldungen gibt, laesst sich die Bedeutung eines Feldes nicht mehr
# aendern (Typ, Auswahl, Pflicht), sonst passten vorhandene Antworten nicht
# mehr zur Frage. Text, Hilfetext und Reihenfolge bleiben aenderbar; ein Feld
# wird dann archiviert statt geloescht.
class RefereeCourseField < ApplicationRecord
  include RefereeCourseFieldDefinition

  LOCKED_WITH_ANSWERS = %w[field_type options required].freeze

  belongs_to :referee_course

  scope :active, -> { where(archived_at: nil) }

  validate :meaning_locked_once_registrations_exist, on: :update

  def registrations_exist?
    referee_course.registrations.exists?
  end

  private

  def meaning_locked_once_registrations_exist
    return unless registrations_exist?

    locked = LOCKED_WITH_ANSWERS & changed
    return if locked.empty?

    errors.add(:base, 'Es gibt schon Anmeldungen: Typ, Auswahl und Pflicht lassen sich nicht mehr ändern')
  end
end
