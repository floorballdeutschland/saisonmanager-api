class AddForfaitGoalsToGames < ActiveRecord::Migration[7.2]
  # Bis hierher stand das Ergebnis eines kampflos gewerteten Spiels fest:
  # Game#result leitete es allein aus League#forfait_goals ab (5 bzw. 8). Die
  # Spielordnung kennt aber Faelle, in denen die SBK ein abweichendes Ergebnis
  # festsetzt -- etwa wenn das Spiel stattgefunden hat und das erzielte Ergebnis
  # zugunsten der nicht schuldigen Mannschaft bestehen bleibt.
  #
  # NULL heisst weiterhin "Liga-Vorgabe", die Spalten sind also rein additiv:
  # jedes bestehende Spiel behaelt sein bisher berechnetes Ergebnis.
  def change
    add_column :games, :forfait_home_goals, :integer
    add_column :games, :forfait_guest_goals, :integer
  end
end
