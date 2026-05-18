class AddLeagueIdDirectEncountersToLeagues < ActiveRecord::Migration[7.0]
  def change
    add_column :leagues, :league_id_direct_encounters, :bigint
  end
end
