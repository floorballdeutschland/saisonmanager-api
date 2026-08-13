class AddRefereeAssignmentSwitchesToStateAssociations < ActiveRecord::Migration[7.1]
  # Der eine Schalter `referee_assignment_enabled` steuerte bisher beides: die
  # Markierung im Spiel-Editor und die Menüpunkte der Ansetzer-Rolle. Aufgeteilt
  # in drei gestaffelte Optionen (siehe StateAssociation#referee_assignment_mode):
  #
  #   1. referee_assignment_external_enabled – Hauptschalter, Ansetzung überhaupt
  #      außerhalb der SBK (Weg 3, RSK pflegt Verein oder Freitext)
  #   2. referee_assignment_enabled          – Personenebene (Weg 2, Ansetzer-Rolle);
  #      Spaltenname bleibt, nur das Label wird umbenannt
  #   3. person_level_assignment_default     – neue Spiele gleich für die
  #      Personenebene markieren
  def up
    add_column :state_associations, :referee_assignment_external_enabled, :boolean, default: false, null: false
    add_column :state_associations, :person_level_assignment_default, :boolean, default: false, null: false

    # Ohne diesen Backfill verlieren alle Landesverbände, die Weg 2 heute nutzen,
    # mit dem Deploy ihre Ansetzung: die Personenebene greift künftig nur bei
    # aktivem Hauptschalter.
    execute <<~SQL.squish
      UPDATE state_associations
         SET referee_assignment_external_enabled = TRUE
       WHERE referee_assignment_enabled = TRUE
    SQL
  end

  def down
    remove_column :state_associations, :person_level_assignment_default
    remove_column :state_associations, :referee_assignment_external_enabled
  end
end
