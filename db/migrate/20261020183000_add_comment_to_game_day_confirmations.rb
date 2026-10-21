# Freitext zum Einspruch gegen den Spieltagsbericht: Bisher konnten Gastteam
# und Schiedsrichter nur die einzelnen Punkte verneinen, aber nicht sagen, was
# genau schiefgelaufen ist. Die SBK musste dafür nachfragen.
class AddCommentToGameDayConfirmations < ActiveRecord::Migration[7.2]
  def change
    add_column :game_day_team_confirmations, :comment, :text
    add_column :game_day_referee_confirmations, :comment, :text
  end
end
