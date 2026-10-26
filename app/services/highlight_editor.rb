# frozen_string_literal: true

# Kalibrierung und Szenenauswahl eines Tablet-Spiels (fe#560).
#
# Nach dem Spiel stellt jemand den Versatz zwischen Halle und Bild ein und wählt,
# welche Szenen in die öffentlichen Highlights kommen. Erreicht wird das über
# den Mail-Link (TabletHighlightRequest) oder als Admin bzw. SBK des
# Spielbetriebs mit Sitzung.
#
# Gilt für DIE Übertragung, die auch GameHighlights zeigt (öffentlich verlinkt,
# meiste Szenen). Ohne sie gibt es nichts zu kalibrieren: `video_id` ist dann
# nil, und Schreiben antwortet mit einem Fehler.
#
# Der Versatz wirkt über StreamTimeline auf Highlights UND Sprungmarken. Die
# Marken schreibt der Wächter beim nächsten Lauf neu, weil sich ihr Block und
# damit `chapters_digest` ändert; hier wird YouTube nicht angefasst. Liegt das
# Streamende schon länger als StreamChapters::MAX_AGE zurück, holt das
# Zurücksetzen von `chapters_checked_at` die Aufzeichnung in den nächsten Lauf
# (StreamChapters#nachzurechnen nimmt kalibrierte Aufzeichnungen mit, auch wenn
# sie noch nie beschrieben wurden).
#
# TOR-ZUORDNUNG: Welcher Tablet-Schuss zu welchem Tor des Berichts gehört,
# ordnet GameShotLinker automatisch zu. Ohne Spielzeit an den Schüssen geht das
# nach der Reihenfolge, und ein einziger als Tor getippter Fehlschuss verschiebt
# alle späteren Tore um eins (Spiel 58763, 24.10.2026). Hier lässt sich das mit
# dem Video vor Augen korrigieren: `goals` listet die Tore des Berichts, Tor-Schüsse
# ohne Tor stehen als Szene `kind: 'unlinked'` in der Liste (nur im Editor,
# öffentlich nie), und `assignments` hängt Schüsse um oder macht sie zum
# Fehlschuss.
class HighlightEditor
  class Invalid < StandardError; end

  # Was ein Tor-Schuss werden kann, der doch keiner war.
  ERGEBNISSE_OHNE_TOR = %w[saved missed blocked].freeze

  attr_reader :game

  def initialize(game)
    @game = game
  end

  def broadcast
    best&.first
  end

  def as_json(*)
    beste = best
    if beste.nil?
      return { game: game_json, video_id: nil, offset_seconds: nil, calibrated_at: nil, calibration_scene: nil,
               goals: goals_json, scenes: [] }
    end

    broadcast, scenes = beste
    timeline = StreamTimeline.new(game, broadcast)
    szenen = (scenes + unlinked_scenes(timeline)).sort_by { |scene| scene[:start] }
                                                 .map { |scene| scene_json(scene, timeline) }
    {
      game: game_json,
      video_id: broadcast.broadcast_id,
      offset_seconds: broadcast.offset_seconds,
      calibrated_at: broadcast.calibrated_at&.utc&.iso8601,
      calibration_scene: szenen.find { |scene| scene[:kind] == 'goal' }&.slice(:client_uuid, :anchor_second),
      goals: goals_json,
      scenes: szenen
    }
  end

  # `offset_seconds`: Ganzzahl oder nil (Kalibrierung zurücknehmen), fehlt der
  # Schlüssel, bleibt der Versatz. `scenes`: [{ client_uuid, in_highlights }].
  # `assignments`: [{ client_uuid, event_id }] hängt einen Tor-Schuss an ein
  # Tor, [{ client_uuid, event_id: nil, result }] macht ihn zum Fehlschuss.
  # Alles oder nichts.
  def update!(params, user: nil)
    beste = best
    raise Invalid, 'Für dieses Spiel gibt es keine veröffentlichte Aufzeichnung.' if beste.nil?

    broadcast = beste.first
    auswahl = auswahl_aus(params[:scenes])
    zuordnung = zuordnung_aus(params[:assignments])
    StreamBroadcast.transaction do
      versatz_setzen!(broadcast, params[:offset_seconds], user) if params.key?(:offset_seconds)
      auswahl.each { |shot, sichtbar| shot.update!(in_highlights: sichtbar) }
      zuordnen!(zuordnung)
    end
    nach_zuordnung(broadcast) if zuordnung.any?
    GameShotStats.flush!(game)
    @best = nil
  end

  private

  def best
    @best ||= GameHighlights.new(game, include_hidden: true).best
  end

  def game_json
    {
      id: game.id,
      game_number: game.game_number,
      home_team_name: game.home_team_name,
      guest_team_name: game.guest_team_name
    }
  end

  def scene_json(scene, timeline)
    {
      client_uuid: scene[:client_uuid],
      kind: scene[:kind],
      label: label(scene),
      team: scene[:team],
      period: scene[:period],
      game_time: scene[:game_time],
      event_id: scene[:event_id],
      anchor_second: timeline.anchor_second(scene[:anchor_at]),
      start: scene[:start],
      end: scene[:end],
      in_highlights: scene[:in_highlights]
    }
  end

  # "1:0 Müller (Schmidt)" wie in den Sprungmarken, sonst "Vorgemerkte Szene".
  def label(scene)
    return 'Tor-Schuss ohne Tor im Bericht' if scene[:kind] == 'unlinked'
    return 'Vorgemerkte Szene' unless scene[:kind] == 'goal'

    event = tore.find { |e| e[:event_id].to_i == scene[:event_id] }
    event ? StreamChapters.marken_text(game, event) : 'Tor'
  end

  def tore
    @tore ||= game.formatted_events.select { |event| event[:event_type] == :goal }
  end

  # Ohne Eigentore und technische Tore: Ihnen lässt sich kein Schuss zuordnen.
  def goals_json
    tore.reject { |event| GameShotLinker.without_shot?(event) }.map do |event|
      { event_id: event[:event_id].to_i, label: StreamChapters.marken_text(game, event),
        team: event[:event_team].to_s, period: event[:period].to_i, time: event[:time].to_s }
    end
  end

  # Tor-Schüsse ohne Tor, als Szene in derselben Form wie GameHighlights sie
  # liefert. Nur hier: Für die Wahl der Übertragung zählen sie nicht.
  def unlinked_scenes(timeline)
    game.game_shots.shots.where(result: 'goal', event_id: nil).filter_map do |shot|
      start, ende = timeline.scene(shot.tapped_at)
      next if start.nil?

      { kind: 'unlinked', event_id: nil, client_uuid: shot.client_uuid, team: shot.team, period: shot.period,
        game_time: shot.game_time.to_s, anchor_at: shot.tapped_at, start: start, end: ende,
        in_highlights: shot.in_highlights }
    end
  end

  def versatz_setzen!(broadcast, wert, user)
    unless wert.nil? || wert.is_a?(Integer) || wert.to_s.match?(/\A-?\d+\z/)
      raise Invalid, 'offset_seconds muss eine ganze Zahl sein.'
    end

    versatz = wert&.to_i
    if versatz && !StreamBroadcast::OFFSET_RANGE.cover?(versatz)
      raise Invalid, "Der Versatz muss zwischen #{StreamBroadcast::OFFSET_RANGE.min} und " \
                     "#{StreamBroadcast::OFFSET_RANGE.max} Sekunden liegen."
    end

    if versatz.nil?
      broadcast.update!(offset_seconds: nil, calibrated_at: nil, calibrated_by_user_id: nil, calibrated_via: nil,
                        chapters_checked_at: nil)
    else
      broadcast.update!(offset_seconds: versatz, calibrated_at: Time.current, calibrated_by_user_id: user&.id,
                        calibrated_via: user ? 'user' : 'link', chapters_checked_at: nil)
    end
  end

  # [[GameShot, Boolean], …]. Nur Tor-Schüsse mit Szene und vorgemerkte
  # Szenen dieses Spiels; Freischläge und fremde Kennungen weist das ab.
  def auswahl_aus(eintraege)
    return [] if eintraege.nil?
    raise Invalid, 'scenes muss eine Liste sein.' unless eintraege.is_a?(Array)
    raise Invalid, 'Jede Szene braucht client_uuid und in_highlights.' unless eintraege.all?(Hash)

    erlaubt = best.last.to_h { |scene| [scene[:client_uuid], true] }
    shots = game.game_shots.where(client_uuid: eintraege.map { |e| e[:client_uuid].to_s }).index_by(&:client_uuid)
    eintraege.map do |eintrag|
      uuid = eintrag[:client_uuid].to_s
      raise Invalid, "Szene #{uuid} gibt es in diesem Spiel nicht." unless erlaubt[uuid] && shots[uuid]
      unless [true, false].include?(eintrag[:in_highlights])
        raise Invalid, "Szene #{uuid}: in_highlights muss true oder false sein."
      end

      [shots[uuid], eintrag[:in_highlights]]
    end
  end

  # [[GameShot, event_id oder nil, Ergebnis oder nil], …]. Jeder Tor-Schuss
  # (keine Freischläge) dieses Spiels darf umgehängt werden, jedes Tor nur
  # einmal, und nur an die eigene Mannschaft.
  def zuordnung_aus(eintraege)
    return [] if eintraege.nil?
    raise Invalid, 'assignments muss eine Liste sein.' unless eintraege.is_a?(Array)
    raise Invalid, 'Jede Zuordnung braucht client_uuid.' unless eintraege.all?(Hash)

    uuids = eintraege.map { |e| e[:client_uuid].to_s }
    raise Invalid, 'Ein Schuss steht doppelt in assignments.' if uuids.uniq.size != uuids.size

    eintraege = eintraege.map { |e| e.merge(event_id: tor_kennung(e[:event_id])) }
    ziele = eintraege.filter_map { |e| e[:event_id] }
    raise Invalid, 'Ein Tor kann nur einen Schuss bekommen.' if ziele.uniq.size != ziele.size

    shots = game.game_shots.shots.where(result: 'goal', client_uuid: uuids).index_by(&:client_uuid)
    eintraege.map { |eintrag| zuordnung_eintrag(eintrag, shots[eintrag[:client_uuid].to_s]) }
  end

  # nil oder eine ganze Zahl (auch als Text). Alles andere (false, Liste,
  # Objekt, 1.5) ist ein Fehler des Aufrufers und darf nicht als 500 enden.
  def tor_kennung(wert)
    return nil if wert.nil?
    return wert if wert.is_a?(Integer)
    return wert.to_i if wert.is_a?(String) && wert.match?(/\A\d+\z/)

    raise Invalid, 'event_id muss eine ganze Zahl oder null sein.'
  end

  def zuordnung_eintrag(eintrag, shot)
    raise Invalid, "Szene #{eintrag[:client_uuid]} ist kein Tor-Schuss dieses Spiels." if shot.nil?

    if eintrag[:event_id].nil?
      ergebnis = eintrag[:result].to_s
      unless ERGEBNISSE_OHNE_TOR.include?(ergebnis)
        raise Invalid, "Szene #{shot.client_uuid}: ohne Tor braucht es result #{ERGEBNISSE_OHNE_TOR.join('/')}."
      end

      return [shot, nil, ergebnis]
    end

    tor = tore.find { |event| event[:event_id].to_i == eintrag[:event_id] }
    raise Invalid, 'Tor nicht gefunden.' if tor.nil?
    raise Invalid, 'Eigentore und technische Tore haben keinen Schuss.' if GameShotLinker.without_shot?(tor)
    raise Invalid, 'Schuss und Tor gehören zu verschiedenen Teams.' if tor[:event_team].to_s != shot.team

    [shot, tor[:event_id].to_i, nil]
  end

  # Erst alle beteiligten Schüsse und Tore lösen, dann neu setzen: So geht auch
  # ein Tausch (A an das Tor von B und umgekehrt) in einem Schritt. Ein Schuss
  # außerhalb der Liste, der an einem Ziel-Tor hing, bleibt als Tor-Schuss ohne
  # Tor stehen, wie beim Verknüpfen am Tablet.
  def zuordnen!(zuordnung)
    return if zuordnung.empty?

    ziele = zuordnung.filter_map { |_shot, event_id, _ergebnis| event_id }
    game.game_shots.where(id: zuordnung.map { |shot, _e, _r| shot.id }).update_all(event_id: nil)
    game.game_shots.where(event_id: ziele).update_all(event_id: nil) if ziele.any?
    zuordnung.each do |shot, event_id, ergebnis|
      shot.reload
      event_id ? shot.update!(event_id: event_id) : shot.update!(result: ergebnis)
    end
  end

  # Szenen und Sprungmarken folgen sofort: Die öffentlichen Highlights liegen
  # eine Minute im Cache, und eine länger zurückliegende Aufzeichnung kommt nur
  # über `chapters_checked_at` wieder in den Wächterlauf.
  def nach_zuordnung(broadcast)
    %w[delayed realtime].each { |variant| Rails.cache.delete(GameHighlights.cache_key(game, variant)) }
    broadcast.update_columns(chapters_checked_at: nil)
  end
end
