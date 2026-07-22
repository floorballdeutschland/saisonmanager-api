class AddNationalToGameOperations < ActiveRecord::Migration[7.1]
  # Explizites "national"-Flag für den Bundesspielbetrieb (Floorball
  # Deutschland). Bisher wurde die Bundesebene aus `state_association_id IS NULL`
  # abgeleitet; seit die FD-GameOperation mit ihrer StateAssociation verknüpft
  # ist (für das Verbandslogo), trägt dieses Signal nicht mehr und die global
  # gescopten FD-Rollen (SBK/RSK/Ansetzer) verloren ihren Verbands-übergreifenden
  # Zugriff. Das Flag entkoppelt "national" von der Logo-Verknüpfung.
  def up
    add_column :game_operations, :national, :boolean, default: false, null: false

    # Bestehenden Bundesspielbetrieb markieren (Floorball Deutschland).
    execute(<<~SQL.squish)
      UPDATE game_operations SET national = TRUE WHERE name = 'Floorball Deutschland'
    SQL
  end

  def down
    remove_column :game_operations, :national
  end
end
