# Aufbereitung eines Spiels für die Livestream-Overlays (OBS-Browser-Quellen).
#
# Setzt auf Game#full_hash auf, ergänzt aber das, was eine Grafik braucht und
# der öffentliche Hash nicht liefert:
#
#   1. Namen zu den Trikotnummern. Game#formatted_events gibt in `number` und
#      `assist` Trikotnummern zurück, keine Spieler. Die Zuordnung gehört
#      serverseitig gemacht und nicht in jede Bauchbinde einzeln.
#   2. `last_goal`, das zuletzt gefallene Tor bereits aufgelöst, damit die
#      Torschützen-Bauchbinde nichts mehr suchen muss.
# `server_time` steht bewusst NICHT hier, sondern nur in der Antwort des
# Controllers: Dieser Hash wird eine Minute lang zwischengespeichert, ein darin
# eingebackener Zeitstempel wäre also bis zu eine Minute alt und der
# Uhrenabgleich damit wertlos.
#
# Bewusst kein Teil von Game: Das Modell hat rund 1.500 Zeilen, und diese
# Aufbereitung hat genau einen Abnehmer.
class OverlayPayload
  # Pseudo-Trikotnummern aus dem Spielbericht. Sie stehen anstelle eines
  # Schützen, nicht für einen Spieler (Game#formatted_events setzt daraus
  # goal_type „owngoal" bzw. „not_assigned"). Ein Namensnachschlag muss sie
  # überspringen, sonst steht in der Bauchbinde eine leere Zeile.
  PSEUDO_NUMBERS = [1000, 2000].freeze

  def initialize(game)
    @game = game
  end

  def as_json(*)
    base = @game.full_hash

    {
      id: base[:id],
      game_number: base[:game_number],
      date: base[:date],
      start_time: base[:start_time],
      actual_start_time: base[:actual_start_time],

      started: base[:started],
      ended: base[:ended],
      game_status: base[:game_status],
      ingame_status: base[:ingame_status],
      current_period_title: base[:current_period_title],
      period_titles: base[:period_titles],

      result: base[:result],
      result_string: base[:result_string],

      home: team_hash('home', base),
      guest: team_hash('guest', base),

      events: resolved_events,
      last_goal: last_goal,

      players: base[:players],
      starting_players: base[:starting_players],

      league: {
        id: base[:league_id],
        name: base[:league_name],
        short_name: base[:league_short_name],
        game_day: base[:game_day]
      }.merge(league_logo),
      arena: {
        name: base[:arena_name],
        short: base[:arena_short]
      },
      hosting_club: base[:hosting_club],
      referees: base[:referees]
    }
  end

  private

  # Nur ein echtes Ligazeichen, kein Rückfall auf das Verbandslogo: In der
  # Anzeigetafel steht das Zeichen für den Wettbewerb. Ein Landesverbandslogo
  # an derselben Stelle behauptete etwas anderes. Fehlt es, greift im Overlay
  # das mitgelieferte Bundesliga-Zeichen.
  #
  # Deshalb hier ausdrücklich nicht `resolved_logo`: Das ginge für ein
  # Ergebnis, das hier ohnehin verworfen wird, jedes Mal über Spielbetrieb und
  # Landesverband. Diese Aufbereitung läuft bei jeder Spieländerung neu, also
  # bei jedem Tor.
  def league_logo
    league = @game.league
    { logo_url: league.logo.attached? ? league.logo_url : nil }
  end

  def team_hash(side, base)
    team = side == 'home' ? @game.home_team : @game.guest_team

    {
      id: base[:"#{side}_team_id"],
      name: base[:"#{side}_team_name"],
      # Kürzel für die Anzeigetafel; `ticker_short_name` fängt Teams ohne
      # hinterlegtes Kürzel ab.
      short_name: team&.ticker_short_name,
      logo: base[:"#{side}_team_logo"],
      logo_small: base[:"#{side}_team_small_logo"]
    }
  end

  # Trikotnummer -> Spieler, getrennt nach Mannschaft. Aufstellungen sind je
  # Spiel höchstens ein paar Dutzend Einträge, deshalb einmal aufgebaut und
  # danach nachgeschlagen statt je Ereignis durchsucht.
  def roster
    @roster ||= begin
      players = @game.players || {}
      %w[home guest].index_with do |side|
        # Ohne Trikotnummer aussortieren: `nil.to_i` ergibt 0, und damit
        # bekäme ein Tor mit der Nummer 0 einen beliebigen nummernlosen
        # Spieler zugeschrieben. Mehrere solche Einträge lägen zudem auf
        # demselben Schlüssel.
        (players[side] || [])
          .select { |p| p['trikot_number'].present? }
          .index_by { |p| p['trikot_number'].to_i }
      end
    end
  end

  def player_for(side, number)
    return nil if number.blank? || PSEUDO_NUMBERS.include?(number.to_i)

    roster[side.to_s]&.[](number.to_i)
  end

  # Anzeigename für Grafiken: Vorname abgekürzt, damit lange Namen die
  # Bauchbinde nicht sprengen. Der volle Name steht daneben, wenn Platz ist.
  def display_name(player)
    return nil if player.blank?

    first = player['player_firstname'].to_s.strip
    last = player['player_name'].to_s.strip
    return last if first.blank?
    return first if last.blank?

    "#{first[0]}. #{last}"
  end

  def resolved_events
    @resolved_events ||= @game.formatted_events.map do |event|
      side = event[:event_team]
      scorer = player_for(side, event[:number])
      assist = player_for(side, event[:assist])

      event.merge(
        scorer_name: display_name(scorer),
        scorer_full_name: full_name(scorer),
        scorer_player_id: scorer&.dig('player_id'),
        assist_name: display_name(assist),
        assist_full_name: full_name(assist)
      )
    end
  end

  def full_name(player)
    return nil if player.blank?

    [player['player_firstname'], player['player_name']].compact_blank.join(' ').presence
  end

  # Das zuletzt gefallene Tor, nach Abschnitt und Uhrzeit. `sortkey` ist bereits
  # so aufgebaut, dass er sich vergleichen lässt (Game#formatted_events).
  def last_goal
    resolved_events.select { |e| e[:event_type] == :goal }.max_by { |e| e[:sortkey].to_s }
  end
end
