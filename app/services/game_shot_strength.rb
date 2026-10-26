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
# - Unterzahl bringen `penalty_2`, `penalty_2and2` und `penalty_5`. Die
#   persönliche Strafe über zehn Minuten nicht, sie kommt immer zusammen mit
#   einer Zeitstrafe, die als eigenes Ereignis daneben steht.
# - MATCHSTRAFEN (MATCH_PENALTIES: `penalty_ms_full`, `penalty_ms_tech` und
#   die ausgeblendeten Spielstrafen `penalty_ms1` bis `penalty_ms3`) ziehen
#   immer eine Bankstrafe 2+2 nach sich, auch wenn die nicht als eigenes
#   Ereignis im Bericht steht. Sie zählen deshalb ab ihrem Zeitpunkt wie
#   eine 2+2. Steht beim selben Team im selben Abschnitt zur selben Zeit
#   zusätzlich eine 2+2 oder (Altdaten) eine 5, ist das diese Bankstrafe:
#   Dann zählt die Matchstrafe nicht noch einmal, je eingetragener Strafe
#   wird eine Matchstrafe aufgewogen.
# - Eine kleine Strafe (auch die erste Hälfte von 2+2) endet, wenn die
#   Gegenseite IN ÜBERZAHL trifft, und zwar genau eine, die als nächste
#   ablaufen würde. Die zweite Hälfte von 2+2 läuft ab dem Tor zwei Minuten.
#   Die Strafe über fünf Minuten läuft immer ganz ab.
# - Gerechnet wird in zeitlicher Reihenfolge, weil jedes Tor vom Zustand nach
#   den vorherigen Toren abhängt.
#
# Daraus die Spielstärke als das, was auf dem Feld steht: Feldspieler des
# schießenden Teams (6 abzüglich seiner laufenden Strafen) gegen die des
# Gegners (5 abzüglich dessen Strafen). Je Team zählen höchstens zwei Strafen,
# mehr Unterzahl gibt es nicht. Strafen beider Teams heben sich dabei NICHT
# auf: Eine Strafe auf jeder Seite plus Torwart raus ist '5v4', nicht '6v5'.
# Möglich sind '6v5', '6v4', '6v3', '5v5', '5v4', '5v3', '4v5', '4v4', '4v3'.
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
  # Alle Matchstrafen des Katalogs (Setting#penalties), zählen wie eine 2+2.
  MATCH_PENALTIES = %w[penalty_ms_full penalty_ms_tech penalty_ms1 penalty_ms2 penalty_ms3].freeze
  MATCH_BENCH_PENALTY = 'penalty_2and2'
  # Eingetragene Strafen, die als Bankstrafe einer Matchstrafe gelten.
  MATCH_BENCH_EQUIVALENTS = %w[penalty_2and2 penalty_5].freeze
  # Diese enden vorzeitig bei einem Überzahltor.
  MINOR = %w[penalty_2 penalty_2and2].freeze
  MINOR_PART = 120
  MAX_SHORT = 2
  # Ohne Abschnittslänge: Abschnitte so weit auseinander, dass keine Strafe
  # hinüberläuft.
  PERIOD_GAP = 100_000

  # Die Gruppen der Summen in GameShotStats: die zwei häufigen Fälle einzeln,
  # alle übrigen bekannten Stärken als 'other', ohne Zeitpunkt 'unknown'.
  BUCKETS = %w[6v5 6v4].freeze
  OTHER = 'other'
  UNKNOWN = 'unknown'

  def initialize(game)
    league = game.game_day&.league
    length = league ? league.period_length.to_i : 0
    @period_seconds = length.positive? ? length * 60 : nil
    @regular_periods = league&.period_count_normal_game
    events = game.formatted_events
    @events_by_id = events.index_by { |event| event[:event_id].to_s }
    @penalties = penalties(events)
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
    "#{6 - own}v#{5 - opponent}"
  end

  # Gruppe für die Summen: '6v5', '6v4', 'other' oder 'unknown'.
  def self.bucket(strength)
    return UNKNOWN if strength.nil?

    BUCKETS.include?(strength) ? strength : OTHER
  end

  private

  def shot_time(shot)
    event = @events_by_id[shot.event_id.to_s] if shot.event_id.present?
    return absolute(event[:period], event[:time]) if event

    absolute(shot.period, shot.game_time)
  end

  # Strafen mit Unterzahl; Matchstrafen als 2+2, sofern ihre Bankstrafe nicht
  # schon eingetragen ist (siehe Klassenkommentar).
  def penalties(events)
    strafen = events.select { |event| event[:event_type] == :penalty }
    bankstrafen = strafen.select { |event| MATCH_BENCH_EQUIVALENTS.include?(event[:penalty_type].to_s) }
                         .map { |event| moment(event) }.tally
    strafen.filter_map do |event|
      type = event[:penalty_type].to_s
      if MATCH_PENALTIES.include?(type)
        key = moment(event)
        if bankstrafen[key].to_i.positive?
          bankstrafen[key] -= 1
          next
        end
        type = MATCH_BENCH_PENALTY
      end
      penalty(event, type)
    end
  end

  # Team, Abschnitt und Zeit wie eingetragen.
  def moment(event)
    [event[:event_team].to_s, event[:period].to_i, event[:time].to_s.strip]
  end

  def penalty(event, type)
    duration = DURATION[type]
    start = absolute(event[:period], event[:time])
    return nil if duration.nil? || start.nil?

    minor = MINOR.include?(type)
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
