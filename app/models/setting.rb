class Setting < ApplicationRecord
  # Die Setting-Konfiguration (Single-Row) wird pro Request vielfach gelesen
  # (Saisons, Strafen, Liga-Kategorien …), aber selten geschrieben. Daher das
  # AR-Objekt cachen und per after_commit invalidieren. Die TTL ist nur ein
  # Sicherheitsnetz – maßgeblich ist der Hook, der bei jedem Commit feuert,
  # unabhängig davon, ob die Instanz über `Setting.first` oder `Setting.current`
  # geladen wurde (z. B. admin/penalty_codes schreibt über `Setting.current`).
  after_commit :flush_caches

  # Zwei Ebenen, weil ein Treffer im Rails-Cache hier nicht gratis ist: der
  # MemoryStore serialisiert seine Eintraege (DupCoder) und macht bei JEDEM
  # Lesen ein Marshal.load. Auf Produktion sind das 0,4 ms je Aufruf — fuer
  # sich genommen wenig, aber `.current` hat 75 Aufrufstellen, und in Schleifen
  # ueber Spieler oder Ligen multipliziert sich das (Messung 19.08.2026:
  # 0,93 ms je `current_min_team`, mal 41 Lizenzen eines Spielers = 38 ms fuer
  # eine einzige Zeile der Lizenzliste). Die anfrage-lokale Ebene davor macht
  # daraus einen Lesezugriff pro Anfrage; `flush_caches` raeumt beide ab.
  #
  # Sie ersetzt nicht das Herausziehen aus Schleifenruempfen: 0 ms mal n ist
  # zwar 0, aber der Aufruf selbst bleibt Arbeit. Beides zusammen wirkt.
  def self.current
    Current.setting ||= Rails.cache.fetch('settings/current', expires_in: 1.hour) do
      Setting.first
    end
  end

  # Beide Ebenen von `.current` abraeumen. Einziger Weg, den Zwischenspeicher zu
  # verwerfen — wer an einer Setting-Zeile per `update_column(s)` oder Raw-SQL
  # vorbei an den Callbacks schreibt, muss das hier selbst nachziehen.
  def self.flush_current_cache
    Current.setting = nil
    Rails.cache.delete('settings/current')
  end

  def self.league_class(league_class_id)
    current['league_classes']&.dig(league_class_id.to_s, 'name').to_s
  end

  def self.league_category(league_category_id)
    # &.dig: nil/"" statt NoMethodError, falls die Kategorie-ID nicht (mehr) in
    # Setting.league_categories existiert (analog zu league_class).
    current['league_categories']&.dig(league_category_id.to_s, 'name').to_s
  end

  # Die seasons-SPALTE als Hash, oder {} wenn dort etwas anderes steht. Deckt
  # ausdrücklich nur die Spalte ab, nicht die Einträge darunter — die Form eines
  # Eintrags entscheidet `season_name`. Kein `&.` auf `current`: Ein fehlendes
  # Setting ist eine kaputte Installation und darf krachen, wie überall sonst in
  # dieser Klasse (`current_season_id`, `league_class`, `liveticker_leagues`).
  #
  # Eine Spalte mit falscher Form ist eine harte Fehlkonfiguration, die im
  # Normalbetrieb nicht entsteht. Sie geht nach Sentry, weil das Ergebnis sonst
  # still im `settings/init`-Cache landet: Ein leerer Saison-Umschalter für 30
  # Minuten, ohne dass irgendwo ein Fehler auftaucht.
  def self.seasons_hash
    value = current.seasons
    return value if value.is_a?(Hash)

    if defined?(Sentry)
      Sentry.capture_message("settings.seasons ist kein Hash (#{value.class}), Saisonliste bleibt leer")
    end
    {}
  end

  # Der Eintrag zur laufenden Saison, immer ein Hash. `{}` statt des Rohwerts,
  # wenn dort ein blanker String steht: `current_min_team` und
  # `current_min_league` lesen darauf `['min_team_id']`, und bei einem String
  # sucht das einen Teilstring, liefert nil und wird von deren `|| 0` verschluckt.
  # Der 0-Fallback ist der dokumentierte Weg für einen fehlenden Schlüssel (#168),
  # aber er soll über eine fehlende Angabe entscheiden und nicht über eine
  # Fehlform, die man für eine Angabe hält.
  def self.current_season
    entry = seasons_hash[current_season_id.to_s]
    entry.is_a?(Hash) ? entry : {}
  end

  # Anzeigename einer Saison, oder nil wenn keiner lesbar ist. Die eine Stelle,
  # an der die Form eines EINTRAGS entschieden wird, damit sie nicht an jedem
  # Aufrufer neu hängt: Ein blanker String unter dem Key ergibt bei
  # `entry['name']` still nil (String#[] sucht einen Teilstring, findet keinen),
  # ein fehlender Key bei `entry['name']` einen NoMethodError. Beides fällt hinter
  # `deliver_later` niemandem auf, die Mail kommt einfach nicht oder trägt eine
  # leere Saison.
  #
  # Ein vorhandener Eintrag ohne lesbaren Namen geht nach Sentry: Das ist eine
  # Fehlkonfiguration, und der einzige Weg, von ihr zu erfahren. Ein fehlender
  # Eintrag dagegen ist der Normalfall (Liga ohne Saison) und bleibt still.
  def self.season_name(season_id)
    return nil if season_id.blank?

    entry = seasons_hash[season_id.to_s]
    name = entry.is_a?(Hash) ? entry['name'].presence : entry.presence
    return name if name || entry.nil?

    if defined?(Sentry)
      Sentry.capture_message("Saison #{season_id} hat einen Eintrag ohne lesbaren Namen (#{entry.inspect})")
    end
    nil
  end

  # Startjahr einer Saison (2026/2027 → 2026), oder nil wenn keine Jahreszahl im
  # Namen steht. Saisonnamen sind Freitext aus der Verwaltung und kommen in
  # mehreren Schreibweisen vor („2026/2027", „Saison 2026/27"), deshalb die erste
  # vierstellige Zahl statt `split('/').first`: Letzteres verlangt, dass der Name
  # mit den Ziffern beginnt, und ergibt bei „Saison 2026/27" eine 0.
  def self.season_start_year(season_id)
    season_name(season_id).to_s[/\d{4}/]&.to_i
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
    year = season_start_year(current_season_id)
    return year if year

    fallback = Date.current.month >= 8 ? Date.current.year : Date.current.year - 1
    message = "Saisonname ohne Jahreszahl (season_id=#{current_season_id}, " \
              "name=#{season_name(current_season_id).inspect}) — " \
              "Lizenzjahr-Stichtag fällt auf #{fallback} zurück"
    Rails.logger.error(message)
    # Zusätzlich Sentry: Der Logger allein erzeugt kein Ereignis (die Sentry-Init
    # setzt nur breadcrumbs_logger), die Zeile liegt also im Container-Log und
    # wird gelesen, wenn schon jemand einen Verdacht hat. Der Stichtag steuert
    # laut oben, welche Jahrgänge als beendet gelten.
    Sentry.capture_message(message) if defined?(Sentry)
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

  # name über die Eintragsform aufgelöst, nicht über v['name']: Bei einem blanken
  # String unter dem Key liefert String#[]('name') still nil, und der
  # Saison-Umschalter zeigte dann einen namenlosen Eintrag.
  #
  # Spalte und aktuelle Saison einmal vor der Schleife holen: `season_name` je
  # Schlüssel läse beides erneut (also 2n Cache-Zugriffe statt zwei), und
  # `current_season_id` in der Schleife könnte bei ablaufendem Cache mitten im
  # Durchlauf umspringen — dann passte das `current`-Kennzeichen nicht mehr zur
  # übrigen Liste.
  def self.seasons
    hash = seasons_hash
    active = current_season_id
    hash.map do |k, v|
      name = v.is_a?(Hash) ? v['name'].presence : v.presence
      { id: k.to_i, name: name, current: (k.to_i == active) }
    end.reverse
  end

  # Gleiche Absicherung wie bei seasons_hash, und hier mit größerer Reichweite:
  # League#table liest das bei jeder Tabellenberechnung, also auf jeder
  # öffentlichen Ligaseite. Ein hand-editierter oder per Konsole korrigierter
  # Wert mit falscher Form hätte dort einen 500er ergeben.
  def self.point_corrections(league_id)
    value = current.point_corrections
    return nil unless value.is_a?(Hash)

    entry = value[league_id.to_s]
    return entry if entry.nil? || entry.is_a?(Hash)

    # Der Eintrag pro Liga ist die Form, die eine Konsolen-Korrektur realistisch
    # trifft, und die gefährlichere: League#table rechnet damit weiter. Ein Array
    # ergab dort einen TypeError (500er auf der öffentlichen Ligaseite), ein
    # String rechnete still ohne den Abzug. Beides wird hier zu nil, also zu
    # "keine Korrektur", und geht nach Sentry — eine falsche öffentliche Tabelle
    # ist ein Alarm und keine Notiz.
    if defined?(Sentry)
      Sentry.capture_message("point_corrections fuer Liga #{league_id} hat falsche Form (#{entry.class}), " \
                             'Abzug wird ignoriert')
    end
    nil
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
    Setting.flush_current_cache
    Rails.cache.delete('settings/init')
  end
end
