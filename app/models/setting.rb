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
    # &.dig: nil/"" statt NoMethodError, falls die Kategorie-ID nicht (mehr) in
    # Setting.league_categories existiert (analog zu league_class).
    current['league_categories']&.dig(league_category_id.to_s, 'name').to_s
  end

  # Der seasons-Hash ist nicht typsicher: Je nach Altbestand steht unter einer
  # Saison ein Hash mit 'name' oder ein blanker String, und die Spalte selbst
  # könnte theoretisch gar kein Hash sein. `seasons_hash` fängt beides ab, damit
  # die Aufrufer nicht jeder für sich prüfen müssen.
  def self.seasons_hash
    value = current&.seasons
    value.is_a?(Hash) ? value : {}
  end

  def self.current_season
    seasons_hash[current_season_id.to_s]
  end

  # Anzeigename einer Saison, oder nil wenn keiner lesbar ist. Die eine Stelle,
  # an der die Formfrage entschieden wird, damit sie nicht an jedem Aufrufer neu
  # hängt: Ein blanker String unter dem Key ergibt bei `entry['name']` still nil
  # (String#[] sucht einen Teilstring, findet keinen), ein fehlender Key bei
  # `entry['name']` einen NoMethodError. Beides fällt hinter `deliver_later`
  # niemandem auf, die Mail kommt einfach nicht oder trägt eine leere Saison.
  def self.season_name(season_id)
    return nil if season_id.blank?

    entry = seasons_hash[season_id.to_s]
    entry.is_a?(Hash) ? entry['name'].presence : entry.presence
  end

  # Startjahr der aktiven Saison (2026/2027 → 2026). Maßgeblich überall dort, wo
  # in Lizenzjahren gerechnet wird: Die Lizenzjahre drehen mit dem manuell
  # ausgeführten Saisonwechsel weiter (nominell zum 01.08.), nicht mit dem
  # Kalenderjahr. Ein vorgezogener Saisonwechsel wirkt dadurch sofort und
  # braucht keine Sonderbehandlung.
  #
  # Saisonnamen sind Freitext aus der Verwaltung und kommen in mehreren
  # Schreibweisen vor („2026/2027", „Saison 2026/27"), deshalb wird die erste
  # vierstellige Jahreszahl gelesen. Der seasons-Hash ist zudem nicht typsicher:
  # Je nach Altbestand steht dort ein Hash mit 'name' oder ein blanker String.
  #
  # Fehlt die Jahreszahl ganz (etwa „Saison 26/27"), wird das protokolliert und
  # auf das Saisonjahr geschätzt — mit August-Grenze, nicht mit dem Kalenderjahr:
  # Von Januar bis Juli läge das Kalenderjahr eins zu hoch und verschöbe den
  # Karriere-Stichtag stumm um ein Jahr, wodurch ganze Jahrgänge auf einmal als
  # beendet gälten und aus Vereins- und öffentlichen Listen verschwänden.
  def self.current_season_start_year
    name = season_name(current_season_id)
    year = name.to_s[/\d{4}/]&.to_i
    return year if year

    fallback = Date.current.month >= 8 ? Date.current.year : Date.current.year - 1
    Rails.logger.error(
      "Saisonname ohne Jahreszahl (season_id=#{current_season_id}, name=#{name.inspect}) — " \
      "Lizenzjahr-Stichtag fällt auf #{fallback} zurück"
    )
    fallback
  end

  # Global konfigurierbare Standard-Spieldauer (inkl. Puffer) in Minuten für die
  # Hallenbelegungs-/Konfliktprüfung. nil, solange nichts gepflegt ist — die
  # League fällt dann auf ihr perioden-basiertes Verhalten zurück.
  def self.default_game_duration_minutes
    systems = current.systems
    return nil unless systems.is_a?(Hash)

    systems.dig('1', 'game_duration_minutes').presence&.to_i
  end

  # EINZIGE Quelle für die aktive Saison. Im seasons-Hash gab es früher zusätzlich
  # ein gespeichertes `current: true`; das wurde von nichts mehr gepflegt, stand
  # zuletzt auf einer abgeschlossenen Saison und ist entfernt (Migration
  # RemoveStaleCurrentFlagFromSeasons). Also nie wieder ein Flag in seasons
  # schreiben oder lesen — immer diese Methode nutzen.
  #
  # Achtung beim Vergleichen: Der Wert ist ein Integer, `leagues.season_id`
  # kommt als String zurück. Also `.to_s`/`.to_i` bewusst setzen.
  def self.current_season_id
    current.systems['1']['current_season_id']
  end

  def self.current_min_league
    current_season['min_league_id'] || 0
  end

  def self.current_min_team
    current_season['min_team_id'] || 0
  end

  # name über season_name, nicht über v['name']: Bei einem blanken String unter
  # dem Key liefert String#[]('name') still nil, und der Saison-Umschalter im
  # Frontend zeigte dann einen namenlosen Eintrag.
  def self.seasons
    seasons_hash.keys.map do |k|
      { id: k.to_i, name: season_name(k), current: (k.to_i == current_season_id) }
    end.reverse
  end

  # Redaktionell gepflegte Links auf externe Informationsblätter (floorball.de).
  # Der Key ist der stabile technische Bezeichner, den das Frontend referenziert;
  # die URL wechselt, sobald floorball.de das PDF neu ablegt, und gehört deshalb
  # nicht in den Code. Gepflegt wird sie unter /verwaltung/dokumentarten.
  # Neue Keys hier ergänzen – nur diese sind über die API schreibbar.
  INFO_LINK_KEYS = %w[minor_privacy_bundesliga].freeze

  def self.info_links
    links = current.info_links
    links.is_a?(Hash) ? links : {}
  end

  # nil, solange kein Link gepflegt ist – Aufrufer blenden ihn dann aus, statt
  # eine tote Adresse anzubieten.
  #
  # Robust gegen Fremdformate: Steht unter einem Key ein blanker String statt
  # eines Hash (Konsolen-Korrektur, hand-editiertes JSONB), bräche `dig` mit
  # TypeError ab. Diese Methode hängt an `init`, also am ersten Request jedes
  # Seitenaufbaus – ein einziger schiefer Wert legte damit das komplette
  # öffentliche Frontend lahm.
  def self.info_link_url(key)
    entry = info_links[key.to_s]
    return nil unless entry.is_a?(Hash)

    entry['url'].presence
  end

  # Gleiche Absicherung wie bei seasons_hash, und hier mit größerer Reichweite:
  # League#table liest das bei jeder Tabellenberechnung, also auf jeder
  # öffentlichen Ligaseite. Ein hand-editierter oder per Konsole korrigierter
  # Wert mit falscher Form hätte dort einen 500er ergeben.
  def self.point_corrections(league_id)
    value = current&.point_corrections
    return nil unless value.is_a?(Hash)

    value[league_id.to_s]
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
