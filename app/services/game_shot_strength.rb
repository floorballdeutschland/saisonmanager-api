# frozen_string_literal: true

# Spielstärke bei Schüssen ohne eigenen Torhüter (fe#610).
#
# Die Kennung `extra_attacker` am Schuss sagt nur, dass das schießende Team
# ohne eigenen Torhüter spielt. Wie viele Feldspieler auf jeder Seite stehen,
# ergibt sich erst aus den Strafen, die zum Zeitpunkt des Schusses laufen.
# Die stehen im Spielbericht (`games.events`, gelesen über
# Game#formatted_events wie bei GameShotLinker und OverlayPayload).
#
# Die Regeln sind die der laufenden Strafen auf der Anzeigetafel
# (`overlay/penalties.js` im Frontend, fe#463), hier nach Ruby übertragen:
#
# - Unterzahl bringen nur `penalty_2`, `penalty_2and2` und `penalty_5`. Die
#   persönliche Strafe über zehn Minuten nicht, sie kommt immer zusammen mit
#   einer Zeitstrafe, die als eigenes Ereignis daneben steht. Matchstrafen
#   ebenfalls nicht: Für die Mannschaft zählt nur eine dazu eingetragene
#   Zeitstrafe.
# - Eine kleine Strafe (auch die erste Hälfte von 2+2) endet, wenn die
#   Gegenseite IN ÜBERZAHL trifft, und zwar genau eine, die als nächste
#   ablaufen würde. Die zweite Hälfte von 2+2 läuft ab dem Tor zwei Minuten.
#   Die Strafe über fünf Minuten läuft immer ganz ab.
# - Gerechnet wird in zeitlicher Reihenfolge, weil jedes Tor vom Zustand nach
#   den vorherigen Toren abhängt.
#
# Daraus die Spielstärke: Je Team zählen höchstens zwei laufende Strafen (mehr
# Unterzahl gibt es nicht), gleich viele auf beiden Seiten heben sich auf.
# Übrig bleibt die Unterzahl einer Seite:
#
#   '6v5'  Gegner vollzählig
#   '6v4'  Gegner mit einer Strafe mehr (Torwart raus in Überzahl)
#   '6v3'  Gegner mit zwei Strafen mehr
#   '5v5'  schießendes Team selbst mit einer Strafe mehr
#   '4v5'  schießendes Team selbst mit zwei Strafen mehr
#
# Eine Strafe auf jeder Seite plus Torwart raus ist auf dem Feld 5 gegen 4,
# zählt hier aber wie 6 gegen 5: ein Feldspieler mehr, aus demselben Grund.
#
# ZEITPUNKT: Hängt der Schuss an einem Tor des Spielberichts (`event_id`),
# gilt dessen Abschnitt und Zeit, sonst Abschnitt und Spielzeit am Schuss.
# Fehlt die Spielzeit oder ist sie unlesbar, ist die Spielstärke unbekannt
# (nil); geraten wird nichts. Eine Strafe, die in derselben Sekunde beginnt,
# läuft noch nicht (Tor bei angezeigter Strafe, oder die Strafe kam erst nach
# dem Tor). Tore in derselben Sekunde wie der Schuss zählen nicht, das ist in
# aller Regel das Tor dieses Schusses selbst.
#
# ABSCHNITTSWECHSEL: Die Zeiten im Spielbericht laufen je Abschnitt ab 0:00.
# Ist die Abschnittslänge der Liga bekannt (`period_length`), rechnet die
# Klasse auf eine durchgehende Spielzeit um, eine Strafe vom Ende des ersten
# Drittels läuft dann im zweiten weiter. Zeiten ab der Abschnittslänge sind
# schon durchgehend erfasst (kommt in Altdaten vor) und bleiben stehen. Ohne
# Abschnittslänge zählen nur Strafen aus dem Abschnitt des Schusses.
#
# Nicht abgebildet, wie auf der Anzeigetafel: gestapelte Strafen (die dritte
# gleichzeitige beginnt erst, wenn eine abgelaufen ist).
class GameShotStrength
  # Dauer in Sekunden je Strafart, nur Arten mit Unterzahl.
  DURATION = { 'penalty_2' => 120, 'penalty_2and2' => 240, 'penalty_5' => 300 }.freeze
  # Diese enden vorzeitig bei einem Überzahltor.
  MINOR = %w[penalty_2 penalty_2and2].freeze
  MINOR_PART = 120
  MAX_SHORT = 2
  # Ohne Abschnittslänge: Abschnitte so weit auseinander, dass keine Strafe
  # hinüberläuft.
  PERIOD_GAP = 100_000

  # Die Gruppen der Summen in GameShotStats, je Spielstärke.
  BUCKETS = { '6v5' => '6v5', '6v4' => '6v4', '6v3' => '6v3', '5v5' => 'shorthanded',
              '4v5' => 'shorthanded' }.freeze
  UNKNOWN = 'unknown'

  def initialize(game)
    league = game.game_day&.league
    length = league ? league.period_length.to_i : 0
    @period_seconds = length.positive? ? length * 60 : nil
    @regular_periods = league&.period_count_normal_game
    events = game.formatted_events
    @events_by_id = events.index_by { |event| event[:event_id].to_s }
    @penalties = events.filter_map { |event| penalty(event) }
    @goals = events.filter_map { |event| goal(event) }.sort_by { |goal| goal[:at] }
  end

  # '6v5' usw., nil ohne `extra_attacker` oder bei unbekanntem Zeitpunkt.
  def for(shot)
    return nil unless shot.extra_attacker

    at = shot_time(shot)
    return nil if at.nil?

    running = running_at(at)
    own = [running.count { |strafe| strafe[:team] == shot.team }, MAX_SHORT].min
    opponent = [running.count { |strafe| strafe[:team] != shot.team }, MAX_SHORT].min
    both = [own, opponent].min
    "#{6 - (own - both)}v#{5 - (opponent - both)}"
  end

  # Gruppe für die Summen: '6v5', '6v4', '6v3', 'shorthanded' oder 'unknown'.
  def self.bucket(strength)
    BUCKETS.fetch(strength.to_s, UNKNOWN)
  end

  private

  def shot_time(shot)
    event = @events_by_id[shot.event_id.to_s] if shot.event_id.present?
    return absolute(event[:period], event[:time]) if event

    absolute(shot.period, shot.game_time)
  end

  def penalty(event)
    return nil unless event[:event_type] == :penalty

    duration = DURATION[event[:penalty_type].to_s]
    start = absolute(event[:period], event[:time])
    return nil if duration.nil? || start.nil?

    minor = MINOR.include?(event[:penalty_type].to_s)
    parts = minor ? duration / MINOR_PART : 1
    { team: event[:event_team].to_s, start: start, end: start + duration, minor: minor, parts: parts,
      part_length: minor ? MINOR_PART : duration }
  end

  def goal(event)
    return nil unless event[:event_type] == :goal

    at = absolute(event[:period], event[:time])
    at && { team: event[:event_team].to_s, at: at }
  end

  # Strafen, die zum Zeitpunkt `at` laufen, mit allen Toren davor.
  def running_at(at)
    strafen = @penalties.map(&:dup)
    @goals.each do |goal|
      break if goal[:at] >= at

      end_one(strafen, goal)
    end
    strafen.select { |strafe| strafe[:start] < at && at < strafe[:end] }
  end

  # Ein Tor in Überzahl beendet die kleine Strafe der Gegenseite, die als
  # nächste abliefe (bei 2+2 deren erste Hälfte).
  def end_one(strafen, goal)
    running = strafen.select { |strafe| strafe[:start] <= goal[:at] && goal[:at] < strafe[:end] }
    short = running.reject { |strafe| strafe[:team] == goal[:team] }
    return if short.size <= running.size - short.size

    target = short.select { |strafe| strafe[:minor] }.min_by { |strafe| strafe[:end] }
    return if target.nil?

    target[:parts] -= 1
    target[:end] = goal[:at] + (target[:parts] * target[:part_length])
  end

  # Zeit „m:ss" im Abschnitt als Sekunden einer durchgehenden Spielzeit.
  def absolute(period, time)
    match = /\A(\d{1,3}):(\d{2})\z/.match(time.to_s.strip)
    nummer = period.to_i
    return nil if match.nil? || nummer < 1

    seconds = (match[1].to_i * 60) + match[2].to_i
    return ((nummer - 1) * PERIOD_GAP) + seconds if @period_seconds.nil?
    return seconds if nummer > 1 && seconds >= @period_seconds

    ([nummer - 1, @regular_periods.to_i].min * @period_seconds) + seconds
  end
end
