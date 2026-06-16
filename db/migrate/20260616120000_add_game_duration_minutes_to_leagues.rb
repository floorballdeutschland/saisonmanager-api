class AddGameDurationMinutesToLeagues < ActiveRecord::Migration[7.1]
  def change
    add_column :leagues, :game_duration_minutes, :integer,
               comment: 'Angenommene Spieldauer inkl. Puffer in Minuten für die ' \
                        'Hallenbelegungs-/Konfliktprüfung; nil = globaler Default / ' \
                        'perioden-basierter Fallback'
  end
end
