# Mehrere Vorrunden-Ligen je Liga (Bayern: Vorrunde in Staffel A und B, danach
# Zwischen- bzw. Meister- und Platzierungsrunde mit den Punkten BEIDER
# Staffeln). Bisher trug eine Liga genau eine `league_id_preround`.
#
# Die alte Spalte bleibt und hält die erste Vorrunden-Liga (siehe
# LeaguePrerounds#sync_preround_columns). Darauf stützen sich der
# Altersklassen-Fallback, die Playoff-Erkennung und ältere Clients.
class AddLeagueIdsPreroundToLeagues < ActiveRecord::Migration[7.2]
  def up
    add_column :leagues, :league_ids_preround, :bigint, array: true, default: [], null: false

    execute <<~SQL.squish
      UPDATE leagues SET league_ids_preround = ARRAY[league_id_preround]
      WHERE league_id_preround IS NOT NULL
    SQL
  end

  def down
    remove_column :leagues, :league_ids_preround
  end
end
