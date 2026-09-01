class RefereeQualification < ApplicationRecord
  belongs_to :referee
  belongs_to :referee_qualification_type

  validates :referee_id, uniqueness: { scope: :referee_qualification_type_id,
                                       message: 'hat diese Qualifikation bereits' }
  # api#585: Eine Zusatzqualifikation ohne Ablaufdatum gibt es nicht mehr. Der
  # Bestand wurde vorher mit `referees:backfill_qualification_valid_until`
  # bereinigt -- die Validierung greift ausnahmslos, weil
  # `Admin::RefereesController#sync_qualifications` mit destroy_all + create
  # arbeitet und damit auch jede Bestandszeile neu anlegt. Bliebe irgendwo eine
  # Zeile ohne Datum stehen, haenge der betroffene Schiedsrichter im
  # Bearbeiten-Formular fest, auch bei einer reinen Namensaenderung.
  validates :valid_until, presence: { message: 'muss angegeben werden' }
end
