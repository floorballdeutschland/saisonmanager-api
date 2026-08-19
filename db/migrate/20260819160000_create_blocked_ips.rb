# Dauerhaft abgewiesene Adressen, bisher eine Konstante in
# config/initializers/rack_attack.rb. Als Tabelle, damit ein Admin sie unter
# "System" eintragen und entfernen kann, ohne dass es einen Deploy braucht:
# Eine Sperre entsteht aus einem Betriebsvorfall, und der wartet nicht auf den
# naechsten Release.
#
# `reason` ist Pflicht, nicht Zierde: Der Grund ist das einzige, was einem
# spaeteren Leser erklaert, warum eine Adresse noch gesperrt ist. Ohne ihn
# bleibt ein Eintrag ewig stehen, weil sich niemand traut, ihn zu entfernen.
class CreateBlockedIps < ActiveRecord::Migration[7.2]
  def up
    create_table :blocked_ips do |t|
      t.string :ip, null: false
      t.string :reason, null: false
      t.integer :created_by
      t.timestamps
    end
    add_index :blocked_ips, :ip, unique: true

    # Der bisherige Eintrag aus der Konstante, damit die Sperre den Umzug
    # ueberlebt. Siehe api#490 fuer den Befund.
    execute <<~SQL.squish
      INSERT INTO blocked_ips (ip, reason, created_at, updated_at)
      VALUES ('82.165.87.204',
              'Kein API-Key, geratene Routen, seit Wochen nur 401/404 (api#490)',
              NOW(), NOW())
    SQL
  end

  def down
    drop_table :blocked_ips
  end
end
