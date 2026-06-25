class Setting < ApplicationRecord
  # Die Setting-Konfiguration (Single-Row) wird pro Request vielfach gelesen
  # (Saisons, Strafen, Liga-Kategorien …), aber selten geschrieben. Daher das
  # AR-Objekt cachen und per after_commit invalidieren. Die TTL ist nur ein
  # Sicherheitsnetz – maßgeblich ist der Hook, der bei jedem Commit feuert,
  # unabhängig davon, ob die Instanz über `Setting.first` oder `Setting.current`
  # geladen wurde (z. B. admin/penalty_codes schreibt über `Setting.current`).
  after_commit :flush_caches

  def self.current
    Rails.cache.fetch('settings/current', expires_in: 1.hour) do
      Setting.first
    end
  end

  def self.league_class(league_class_id)
    current['league_classes']&.dig(league_class_id.to_s, 'name').to_s
  end

  def self.league_category(league_category_id)
    current['league_categories'][league_category_id.to_s]['name'].to_s
  end

  def self.current_season
    current.seasons[current_season_id.to_s]
  end

  # Global konfigurierbare Standard-Spieldauer (inkl. Puffer) in Minuten für die
  # Hallenbelegungs-/Konfliktprüfung. nil, solange nichts gepflegt ist — die
  # League fällt dann auf ihr perioden-basiertes Verhalten zurück.
  def self.default_game_duration_minutes
    systems = current.systems
    return nil unless systems.is_a?(Hash)

    systems.dig('1', 'game_duration_minutes').presence&.to_i
  end

  def self.current_season_id
    current.systems['1']['current_season_id']
  end

  def self.current_min_league
    current_season['min_league_id'] || 0
  end

  def self.current_min_team
    current_season['min_team_id'] || 0
  end

  def self.seasons
    current.seasons.map do |k, v|
      { id: k.to_i, name: v['name'], current: (k.to_i == current_season_id) }
    end.reverse
  end

  def self.point_corrections(league_id)
    current.point_corrections[league_id.to_s]
  end

  # {
  #   "game_day_for_league": {
  #     "780": [1,2],
  #     "781": [4,5],
  #     "782": [6,7],
  #     "783": [1,2]
  #   }
  # }.with_indifferent_access

  def self.liveticker_leagues(season_id = current_season_id, _goid = 1)
    current.liveticker['game_day_for_league']&.[](season_id.to_s)&.keys
  end

  def self.game_day_for_league(league_id, season_id = current_season_id)
    current.liveticker['game_day_for_league']&.[](season_id.to_s)&.[](league_id.to_s)
  end

  def self.start_best_of_eight(league_id)
    current.liveticker['cup_best_of_eight']&.[](league_id.to_s)
  end

  private

  # settings/init enthält abgeleitete Setting-Daten (seasons, current_season_id);
  # beim Saison-Anlegen/Wechsel (admin/settings#create_season/update_season) muss
  # dieser Cache ebenfalls fallen, sonst erscheint die neue Saison bis zu 30 min
  # verzögert.
  def flush_caches
    Rails.cache.delete('settings/current')
    Rails.cache.delete('settings/init')
  end
end
