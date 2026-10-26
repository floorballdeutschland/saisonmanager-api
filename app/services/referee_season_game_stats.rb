# Einsatzzahlen eines Schiedsrichters für die laufende Saison und die Vorsaison,
# je einmal über alle Spiele und einmal nur Großfeld ab U15. Grundlage für die
# Lizenzerteilung, deshalb dieselbe Zahl in jeder Sicht: Verein (vm/referees/:id),
# Verband (admin/referees/:id) und der Schiedsrichter selbst
# (referee/history/season_stats).
#
# Gezählt wird über Referee#games, also laut Spielbericht und nicht laut
# Ansetzung, mit denselben Fallbacks auf Lizenznummer und Freitext wie die
# Einsatzhistorie. Ein Spiel zählt je Schiedsrichter einmal.
#
# Beide Saisons hängen allein an Setting.current_season_id. Der manuelle
# Saisonwechsel schiebt sie deshalb ohne weiteres Zutun weiter: Die neue Saison
# startet mit null, die bisherige wird zur Vorsaison. Nichts davon ist
# zwischengespeichert.
class RefereeSeasonGameStats
  # Großfeld ab U15: Feldgröße GF und keine Altersklasse unter U15. Beides über
  # die effective_*-Werte der Liga, weil Playoff- und Endrundenligen die Felder
  # oft leer lassen und dann die Hauptrunde gilt (LeagueCompetition). Eine Liga
  # ohne Altersklasse zählt mit, wie Herren und Damen; eine ohne Feldgröße
  # nicht, weil sich Großfeld dort nicht belegen lässt.
  MIN_AGE = 15

  def self.for(referee)
    new(referee).to_a
  end

  def initialize(referee)
    @referee = referee
  end

  def to_a
    current = Setting.current_season_id.to_i
    season_ids = [current, Setting.previous_season_id].compact.uniq
    rows = @referee.games(season_id: season_ids.map(&:to_s)).pluck('leagues.id', 'leagues.season_id')
    leagues = League.unscoped.where(id: rows.map(&:first).uniq).index_by(&:id)

    season_ids.map do |season_id|
      league_ids = rows.select { |_, s| s.to_i == season_id }.map(&:first)
      {
        season_id: season_id,
        season_name: Setting.season_name(season_id) || season_id.to_s,
        current: season_id == current,
        games: league_ids.size,
        games_gf_u15_plus: league_ids.count { |id| gf_u15_plus?(leagues[id]) }
      }
    end
  end

  private

  def gf_u15_plus?(league)
    return false unless league&.effective_field_size == 'GF'

    age = league.effective_age_group.to_s[/\AU(\d+)/, 1]
    age.nil? || age.to_i >= MIN_AGE
  end
end
