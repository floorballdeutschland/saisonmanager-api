# frozen_string_literal: true

# Schließt beim Saisonwechsel die Spielberichte aller vergangenen Saisons.
#
# Anlass: Ein abgeschlossener Bericht ist gegen Änderungen an Toren, Strafen und
# am Status geschützt (GamesController#add_event/#remove_event/#update_event und
# #set_game_status lassen sie nur noch für Admin und die SBK des Spielbetriebs
# zu). Ein Bericht, der am Saisonende offen geblieben ist, bleibt dagegen für
# jeden bearbeitbar, der ihn ohnehin bearbeiten darf -- und das ist beim
# ausrichtenden Verein auch Jahre später noch der Fall. Der Saisonwechsel ist
# der Moment, an dem der Spielbetrieb der alten Saison endet, also der richtige
# Zeitpunkt, die Berichte zuzumachen.
#
# Läuft beim manuellen Saisonwechsel (Admin::SettingsController#update_season),
# nicht als Cronjob: Wann eine Saison endet, entscheidet der Verband.
#
# Idempotent: Wer schon geschlossen ist, wird nicht angefasst. Ein zweiter Lauf
# findet nichts mehr.
class PastSeasonReportCloser
  CLOSED_STATUSES = %w[match_record_closed finalized].freeze

  Result = Struct.new(:games, :leagues, keyword_init: true)

  def self.call(current_season_id: Setting.current_season_id)
    new(current_season_id).call
  end

  def initialize(current_season_id)
    @current_season_id = current_season_id.to_i
  end

  def call
    league_ids = past_league_ids
    return Result.new(games: 0, leagues: 0) if league_ids.empty?

    betroffen = affected_league_ids(league_ids)
    return Result.new(games: 0, leagues: 0) if betroffen.empty?

    anzahl = close_games(league_ids)
    flush_league_caches(betroffen)

    Result.new(games: anzahl, leagues: betroffen.size)
  end

  private

  # Die Ligen aller Saisons vor der laufenden.
  #
  # Über die Saisonliste aus `Setting.seasons_hash` (dem rohen Hash, nicht der
  # aufbereiteten Liste aus `Setting.seasons`) und eine Aufzählung, nicht über einen
  # Vergleich in SQL: `leagues.season_id` ist eine Textspalte, ein `<` vergliche
  # als Text und nähme die einstelligen Saisons 2…9 gegen eine zweistellige
  # laufende Saison ausgerechnet nicht mit. Eine Liga, deren `season_id` in der
  # Saisonliste gar nicht vorkommt (Altbestand, Rohimport), bleibt unangetastet
  # -- was dort gemeint ist, weiß dieser Weg nicht.
  def past_league_ids
    past_seasons = Setting.seasons_hash.keys.select { |id| id.to_i.positive? && id.to_i < @current_season_id }
    return [] if past_seasons.empty?

    League.where(season_id: past_seasons).pluck(:id)
  end

  def affected_league_ids(league_ids)
    open_games(league_ids).distinct.pluck('game_days.league_id')
  end

  def close_games(league_ids)
    # `update_all` und damit ohne Callbacks: Der reguläre Abschluss zählt
    # Sperren ab (PlayerSuspension.count_closed_game!), füllt Platzierungsspiele
    # und verschickt Mails. Nichts davon gehört zu einem Sammelabschluss alter
    # Saisons. Die Cache-Invalidierung, die sonst am `after_commit` hängt, holt
    # der Aufrufer nach.
    open_games(league_ids).in_batches(of: 1000).sum do |batch|
      batch.update_all(game_status: 'match_record_closed')
    end
  end

  # Offene Berichte der übergebenen Ligen.
  #
  # `game_status IS NULL` muss ausdrücklich dastehen: `NOT IN` ist für NULL
  # nicht wahr, sondern unbekannt -- ein nie begonnener Bericht (im Bestand der
  # Normalfall für ungespielte Partien) fiele sonst aus der Auswahl und bliebe
  # als einziger offen. Der vorhandene Scope `Game.match_record_not_closed`
  # trägt genau diese Lücke.
  def open_games(league_ids)
    Game.joins(:game_day)
        .where(game_days: { league_id: league_ids })
        .where('games.game_status IS NULL OR games.game_status NOT IN (?)', CLOSED_STATUSES)
  end

  # `match_record_closed_at` bleibt bewusst unberührt.
  #
  # Der Zeitstempel beantwortet die Frage „wann haben die Beteiligten den
  # Bericht eingereicht" und ist die Grundlage von Fristen und Auswertungen, die
  # daran hängen. Ein Sammelabschluss Jahre später ist keine Einreichung; ihn
  # auf „jetzt" zu setzen hieße, jeden alten Spieltag als eben erst
  # abgeschlossen auszugeben -- mit allem, was daran hängt.
  def flush_league_caches(league_ids)
    league_ids.each do |league_id|
      %w[schedule current_schedule table grouped_table scorer].each do |key|
        Rails.cache.delete("leagues/#{league_id}/#{key}")
      end
    end
  end
end
