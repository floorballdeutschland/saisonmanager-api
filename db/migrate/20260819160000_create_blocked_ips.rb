# Dauerhaft abgewiesene Adressen. Als Tabelle, damit ein Admin sie unter
# "System" eintragen und entfernen kann, ohne dass es einen Deploy braucht:
# Eine Sperre entsteht aus einem Betriebsvorfall, und der wartet nicht auf den
# naechsten Release.
#
# api#490 hatte die Liste zuerst als Konstante in rack_attack.rb; dieser PR baut
# darauf auf und ersetzt sie. Wird nur dieser PR gemergt, hat es die Konstante
# nie gegeben — der uebernommene Eintrag unten ist dann einfach der Anlassfall.
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

    # Der Anlassfall, damit die Sperre den Umzug ueberlebt (Befund in api#490).
    # Laeuft absichtlich als SQL und damit an den Validierungen vorbei: Zu diesem
    # Zeitpunkt gibt es das Modell in der Migration nicht. Die Adresse ist
    # oeffentlich und der Grund unter 200 Zeichen, beide Regeln also von Hand
    # geprueft. ON CONFLICT, damit ein erneuter Lauf nicht abbricht.
    execute <<~SQL.squish
      INSERT INTO blocked_ips (ip, reason, created_at, updated_at)
      VALUES ('82.165.87.204',
              'Kein API-Key, geratene Routen, seit Wochen nur 401/404 (api#490)',
              NOW(), NOW())
      ON CONFLICT (ip) DO NOTHING
    SQL
  end

  # Nicht verlustfrei: Mit der Tabelle sind alle vom Admin eingetragenen Sperren
  # weg, und die papertrail-Versionen bleiben als Waisen zurueck. Das liegt in
  # der Natur einer create-table-Migration; wer zurueckdreht, sollte die Liste
  # vorher sichern.
  def down
    drop_table :blocked_ips
  end
end
