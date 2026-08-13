class AddIndexToGameDaysDate < ActiveRecord::Migration[7.1]
  # `game_days` ist auf arena_id, club_id, (league_id, number) und legacy_ref
  # indiziert, nicht auf `date`. Drei Stellen vergleichen über diese Spalte:
  # der öffentliche Livestream-Abruf des Tages (bei jedem Cache-Miss),
  # `TeamsController` und `Admin::RefereeAssignmentsController`.
  #
  # Reiner Zeichenketten-Index: Die Spalte ist Text, und alle drei Stellen
  # vergleichen sie auch so (`where(date: ...)`). Ein Ausdrucksindex über
  # TO_DATE würde `past_games` bedienen, aber keinen der drei Gleichheitsfälle,
  # und ihn würde jeder abweichend formatierte Altdatensatz zum Absturz bringen.
  def change
    add_index :game_days, :date
  end
end
