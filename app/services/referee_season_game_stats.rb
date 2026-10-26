# Einsatzzahlen eines Schiedsrichters für die laufende Saison und die Vorsaison,
# je einmal über alle Spiele und einmal nur Großfeld ab U15. Grundlage für die
# Lizenzerteilung, deshalb dieselbe Zahl in jeder Sicht: Verein (vm/referees/:id),
# Verband (admin/referees/:id) und der Schiedsrichter selbst
# (referee/history/season_stats). Die Prüfmaske des Kursimports zeigt die
# Vorsaison daraus (previous_season).
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

  # Nur die Vorsaison, oder nil, wenn es keine gibt. Für die Prüfmaske des
  # Kursimports: Nach einem F-Kurs gibt es L1 statt L2 nur mit mindestens vier
  # Spielen Großfeld ab U15 in der letzten Saison.
  def self.previous_season(referee)
    previous = Setting.previous_season_id
    previous && new(referee, season_ids: [previous]).to_a.first
  end

  # Spiele einer Saison mit frei gewählter Wertung, für die Regeln des
  # Lizenzvorschlags (RefereeLicenseSuggestionRule). `field_size` ist `all`,
  # `KF` oder `GF`; gezählt werden nur die Ligen in `age_groups` (eine leere
  # Liste lässt die Regel nicht zu, siehe dort). Eine Liga ohne Altersklasse
  # zählt immer mit, wie bei games_gf_u15_plus.
  def self.count(referee, season_id:, age_groups:, field_size: 'all')
    league_ids = referee.games(season_id: season_id.to_s).pluck('leagues.id')
    leagues = League.unscoped.where(id: league_ids.uniq).index_by(&:id)
    league_ids.count { |id| league_matches?(leagues[id], field_size, age_groups) }
  end

  def self.league_matches?(league, field_size, age_groups)
    return false if league.nil?
    return false unless field_size == 'all' || league.effective_field_size == field_size

    age = league.effective_age_group
    age.blank? || age_groups.include?(age)
  end
  private_class_method :league_matches?

  def initialize(referee, season_ids: nil)
    @referee = referee
    @season_ids = season_ids
  end

  def to_a
    current = Setting.current_season_id.to_i
    season_ids = @season_ids || [current, Setting.previous_season_id].compact.uniq
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
