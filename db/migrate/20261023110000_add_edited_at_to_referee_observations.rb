# Vermerk „bearbeitet am" am Beobachtungsbogen (feedback#74): Der Coach darf
# seinen abgegebenen Bogen nachträglich korrigieren, und alle Leser sollen sehen,
# dass der Text nicht mehr der ursprünglich abgegebene ist.
class AddEditedAtToRefereeObservations < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_observations, :edited_at, :datetime
  end
end
