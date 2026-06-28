class AddCompositeIndexOnGameDaysLeagueIdAndNumber < ActiveRecord::Migration[7.1]
  # Issue #27: League#games / #game_day_schedule filtern game_days über
  # (league_id [, number]) – der heißeste Pfad, seit #25 Tabelle/Scorer beim
  # Cache-Miss neu aufbaut. Bisher war nur league_id einzeln indiziert.
  #
  # Der zusammengesetzte Index (league_id, number) bedient beide Fälle:
  #   - where(league_id:).where(number:)  → beide Spalten
  #   - reine league_id-Lookups           → Leftmost-Prefix
  # Damit wird der bisherige Einzelindex auf league_id redundant und entfällt
  # (spart Schreib-/Speicher-Overhead).
  def change
    add_index :game_days, %i[league_id number], name: 'index_game_days_on_league_id_and_number'
    remove_index :game_days, column: :league_id, name: 'index_game_days_on_league_id'
  end
end
