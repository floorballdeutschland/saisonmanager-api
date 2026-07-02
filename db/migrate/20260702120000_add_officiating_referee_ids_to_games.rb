# Kanonische, stabile Verknüpfung der tatsächlich eingesetzten Schiedsrichter
# eines Spiels über Referee-PKs (analog nominated_referee_ids für die
# Ansetzung). Bisher lagen die eingesetzten Schiris nur als Freitext
# (referee1/2_string) bzw. als Lizenznummern (referee_ids) vor – Lizenznummern
# sind über den Schiri-Merge wanderbar und daher kein stabiler Schlüssel.
class AddOfficiatingRefereeIdsToGames < ActiveRecord::Migration[7.1]
  def change
    add_column :games, :officiating_referee_ids, :integer, array: true, default: []
    add_index :games, :officiating_referee_ids, using: :gin
  end
end
