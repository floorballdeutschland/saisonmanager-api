# Vorlage fuer Zusatzfelder der Kursanmeldung je Landesverband. Ein neuer Kurs
# uebernimmt die Vorlagen seines LV als eigene Felder (RefereeCourseField), die
# danach pro Kurs geaendert werden koennen. `state_association_id` NULL:
# Vorlage fuer bundesweite Kurse.
class RefereeCourseFieldTemplate < ApplicationRecord
  include RefereeCourseFieldDefinition

  belongs_to :state_association, optional: true

  scope :ordered, -> { order(:position, :id) }
end
