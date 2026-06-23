# frozen_string_literal: true

# Eindeutige, herkunftsstabile Referenz auf den Quelldatensatz des Altsystems
# (z. B. "L:fvd:2013_2014:33"). Macht den Altdaten-Import idempotent und
# nachvollziehbar – unabhängig von Umbenennungen oder doppelten Paarungen.
# Nullable + partieller Unique-Index, damit Bestandsdaten unberührt bleiben.
class AddLegacyRefToImportTables < ActiveRecord::Migration[7.1]
  def change
    %i[leagues teams game_days games].each do |table|
      add_column table, :legacy_ref, :string
      add_index table, :legacy_ref, unique: true, where: 'legacy_ref IS NOT NULL',
                                    name: "index_#{table}_on_legacy_ref"
    end
  end
end
