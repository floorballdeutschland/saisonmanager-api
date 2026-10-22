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
# damit `chapters_digest` ändert; hier wird YouTube nicht angefasst.
class HighlightEditor
  class Invalid < StandardError; end

  attr_reader :game

  def initialize(game)
    @game = game
  end

  def broadcast
    best&.first
  end

  def as_json(*)
    beste = best
    return { game: game_json, video_id: nil, offset_seconds: nil, calibrated_at: nil, calibration_scene: nil, scenes: [] } \
      if beste.nil?

    broadcast, scenes = beste
    timeline = StreamTimeline.new(game, broadcast)
    szenen = scenes.map { |scene| scene_json(scene, timeline) }
    {
      game: game_json,
      video_id: broadcast.broadcast_id,
      offset_seconds: broadcast.offset_seconds,
      calibrated_at: broadcast.calibrated_at&.utc&.iso8601,
      calibration_scene: szenen.find { |scene| scene[:kind] == 'goal' }&.slice(:client_uuid, :anchor_second),
      scenes: szenen
    }
  end

  # `offset_seconds`: Ganzzahl oder nil (Kalibrierung zurücknehmen), fehlt der
  # Schlüssel, bleibt der Versatz. `scenes`: [{ client_uuid, in_highlights }].
  # Alles oder nichts.
  def update!(params, user: nil)
    beste = best
    raise Invalid, 'Für dieses Spiel gibt es keine veröffentlichte Aufzeichnung.' if beste.nil?

    broadcast = beste.first
    auswahl = auswahl_aus(params[:scenes])
    StreamBroadcast.transaction do
      versatz_setzen!(broadcast, params[:offset_seconds], user) if params.key?(:offset_seconds)
      auswahl.each { |shot, sichtbar| shot.update!(in_highlights: sichtbar) }
    end
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
      anchor_second: timeline.anchor_second(scene[:anchor_at]),
      start: scene[:start],
      end: scene[:end],
      in_highlights: scene[:in_highlights]
    }
  end

  # "1:0 Müller (Schmidt)" wie in den Sprungmarken, sonst "Vorgemerkte Szene".
  def label(scene)
    return 'Vorgemerkte Szene' unless scene[:kind] == 'goal'

    event = game.formatted_events.find { |e| e[:event_type] == :goal && e[:event_id].to_i == scene[:event_id] }
    event ? StreamChapters.marken_text(game, event) : 'Tor'
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
      broadcast.update!(offset_seconds: nil, calibrated_at: nil, calibrated_by_user_id: nil, calibrated_via: nil)
    else
      broadcast.update!(offset_seconds: versatz, calibrated_at: Time.current, calibrated_by_user_id: user&.id,
                        calibrated_via: user ? 'user' : 'link')
    end
  end

  # [[GameShot, Boolean], …]. Nur Tor-Schüsse mit Szene und vorgemerkte
  # Szenen dieses Spiels; Freischläge und fremde Kennungen weist das ab.
  def auswahl_aus(eintraege)
    return [] if eintraege.nil?
    raise Invalid, 'scenes muss eine Liste sein.' unless eintraege.is_a?(Array)

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
end
