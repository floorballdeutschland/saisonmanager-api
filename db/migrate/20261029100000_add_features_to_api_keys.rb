# Zusatzpakete je API-Schlüssel (z. B. die ausführliche Statistik). Bisher
# lieferte `games/:id/detailed_stats` an jeden aktiven Schlüssel aus; ab jetzt
# braucht ein Schlüssel die Freigabe ausdrücklich.
#
# Nur die in der Verwaltung von Hand angelegten Schlüssel (eigenes Frontend,
# Prerender-Build, eigene Anwendungen wie das Floorball-Dashboard) behalten die
# ausführliche Statistik, sonst verschwindet sie z. B. von der Spielseite.
# Erkennbar sind sie daran, dass kein Antrag auf sie zeigt, genau wie in der
# Key-Liste („manuell angelegt"). Die Anfragegrenze taugt dafür nicht: Auch
# ein eigener Schlüssel kann eine tragen. Zugänge aus dem Antragsprozess
# verlieren die Statistik.
class AddFeaturesToApiKeys < ActiveRecord::Migration[7.2]
  def up
    add_column :api_keys, :features, :string, array: true, default: [], null: false,
                                              comment: 'Freigegebene Zusatzpakete, siehe ApiKey::FEATURES'
    execute <<~SQL.squish
      UPDATE api_keys SET features = ARRAY['detailed_stats']
      WHERE NOT EXISTS (SELECT 1 FROM api_key_applications a WHERE a.api_key_id = api_keys.id)
    SQL
  end

  def down
    remove_column :api_keys, :features
  end
end
