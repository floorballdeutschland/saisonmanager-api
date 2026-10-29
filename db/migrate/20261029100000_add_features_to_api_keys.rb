# Zusatzpakete je API-Schlüssel (z. B. die ausführliche Statistik). Bisher
# lieferte `games/:id/detailed_stats` an jeden aktiven Schlüssel aus; ab jetzt
# braucht ein Schlüssel die Freigabe ausdrücklich.
#
# Die von Hand angelegten Schlüssel ohne Anfragegrenze (eigenes Frontend,
# Prerender-Build, siehe ApiKey.generate) behalten die ausführliche Statistik,
# sonst verschwindet sie von der Spielseite. Zugänge aus dem Antragsprozess
# tragen immer eine Grenze und starten ohne Freigabe.
class AddFeaturesToApiKeys < ActiveRecord::Migration[7.2]
  def up
    add_column :api_keys, :features, :string, array: true, default: [], null: false,
                                              comment: 'Freigegebene Zusatzpakete, siehe ApiKey::FEATURES'
    execute "UPDATE api_keys SET features = ARRAY['detailed_stats'] WHERE rate_limit IS NULL"
  end

  def down
    remove_column :api_keys, :features
  end
end
