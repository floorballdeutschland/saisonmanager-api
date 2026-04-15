# frozen_string_literal: true

# Remaps player nation_ids from the legacy saisonmanager.de system to the new system.
#
# Background
# ----------
# The legacy system stored ~56 IFF member nations in sequential IDs ordered
# alphabetically in German (1=Australien, 2=Belgien, 3=Dänemark, 4=Deutschland, …).
# The import task (import_legacy_data.rake) preserved the raw nation_id values.
# The new system uses a different scheme (1=Deutschland, 4=Dänemark, 6=Finnland, …).
# This caused ~27,642 German players to display as "Dänemark".
#
# Mapping applied
# ---------------
#   Old 3 (Dänemark)    → New 4  (Dänemark in new system)
#   Old 4 (Deutschland) → New 1  (Deutschland in new system)  ← main fix
#   Old 6 (Finnland)    → New 6  (unchanged — same ID in both)
#   Old 99 (Sonstige)   → New 99 (unchanged)
#   All other legacy IDs (Australien, Belgien, Estland, Frankreich, 8–56, …) → 99 (Sonstige)

class FixPlayerNationIds < ActiveRecord::Migration[7.0]
  def up
    execute(<<~SQL)
      UPDATE players
      SET nation_id = CASE nation_id::text
        WHEN '3'  THEN '4'   -- Dänemark  (old pos 3 → new ID 4)
        WHEN '4'  THEN '1'   -- Deutschland (old pos 4 → new ID 1)
        WHEN '6'  THEN '6'   -- Finnland  (same in both systems)
        WHEN '99' THEN '99'  -- Sonstige  (unchanged)
        ELSE '99'             -- all other legacy IDs → Sonstige
      END
      WHERE nation_id IS NOT NULL
        AND nation_id <> ''
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
