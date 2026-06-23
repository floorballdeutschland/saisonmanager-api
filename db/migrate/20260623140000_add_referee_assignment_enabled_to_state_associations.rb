class AddRefereeAssignmentEnabledToStateAssociations < ActiveRecord::Migration[7.1]
  def change
    # Schaltet die Schiedsrichter-Ansetzungslogik je Landesverband frei (opt-in).
    # National betriebene Spielbetriebe (state_association_id = nil, z. B. FD)
    # gelten unabhängig davon immer als aktiv.
    add_column :state_associations, :referee_assignment_enabled, :boolean, default: false, null: false
  end
end
