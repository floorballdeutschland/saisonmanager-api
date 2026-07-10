class AddGinIndexToGamesPlayers < ActiveRecord::Migration[7.1]
  # Beschleunigt die JSONB-Containment-Query des Spielerstatistik-Endpunkts
  # (players->'home' @> …), die sonst alle Spiele sequenziell scannt.
  def change
    add_index :games, :players, using: :gin, name: 'index_games_on_players'
  end
end
