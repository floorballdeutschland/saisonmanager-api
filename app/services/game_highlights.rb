# frozen_string_literal: true

# Virtuelle Highlights eines Tablet-Spiels (fe#555): je Tor mit verknüpftem
# Schuss eine Szene in der YouTube-Aufzeichnung, ohne ein Video zu schneiden.
#
# Nur Tore mit Tablet-Schuss: `added_at` liegt 1,5 bis über 3 min hinter dem
# Tor (Stichprobe vom 11.10.2026, Spiel 58679) und taugt für eine
# 20-Sekunden-Szene nicht.
#
# KEINE LIVE-ABFRAGE BEI YOUTUBE: Start und Länge der Aufzeichnung stammen aus
# `stream_broadcasts` (gespeichert vom Wächter, StreamChapters). Die Rechnung
# selbst steht in StreamTimeline#scene, dieselbe Stelle wie für die
# Sprungmarken.
#
# AUSWAHL UND VORGEMERKTE SZENEN (fe#560): Öffentlich erscheinen nur Szenen
# mit `in_highlights`. Dazu kommen die im Tablet vorgemerkten Szenen
# (`kind: 'mark'`) mit `kind: 'mark'` im JSON; Tor-Szenen tragen `kind: 'goal'`.
# Freischläge sind nie eine Szene. Der Szenen-Editor (HighlightEditor) liest
# mit `include_hidden: true` auch die abgewählten.
#
# Nur verlinkte Übertragungen (siehe #oeffentliche_uebertragungen). Hat ein
# Spiel mehrere (Neustart nach einem Abbruch), gilt die mit den meisten Szenen,
# gezählt OHNE Auswahl und Verzögerung. Öffentliche Highlights und Editor
# landen so immer auf derselben Übertragung; sonst könnte das Abwählen von
# Szenen öffentlich auf eine andere, unkalibrierte Übertragung umschalten.
# `video_id` ist nil, solange keine Übertragung mit bekanntem Start existiert;
# dann gibt es auch keine Szenen.
#
# `calibrated` sagt, ob die gewählte Übertragung kalibriert ist (fe#560).
# Unkalibriert liegen die Szenen nur ungefähr, die Seite weist darauf hin.
# nil ohne Übertragung.
class GameHighlights
  CACHE_TTL = 1.minute

  def self.cache_key(game, variant)
    "games/#{game.id}/highlights/#{variant}"
  end

  def self.cached(game, delayed:, cutoff: nil)
    Rails.cache.fetch(cache_key(game, delayed ? 'delayed' : 'realtime'), expires_in: CACHE_TTL) do
      new(game, cutoff: cutoff).as_json
    end
  end

  # Nur Übertragungen, die das Spiel selbst verlinkt (`live_stream_link`,
  # `vod_link`). Eine nicht gelistete Aufzeichnung (Probelauf, Zusage an den
  # Verein, noch nicht freigegeben) steht dort nicht; ihre ID herauszugeben
  # hieße, sie öffentlich zu machen. Dieselbe Grenze wie
  # StreamWatchdog#verlinke_aufzeichnung, das den Link erst beim
  # Veröffentlichen setzt.
  def self.oeffentliche_uebertragungen(game)
    links = [game.live_stream_link, game.vod_link].compact_blank
    return [] if links.empty?

    StreamBroadcast.where(game_id: game.id).where.not(actual_start_at: nil)
                   .order(actual_start_at: :desc)
                   .select { |broadcast| links.any? { |link| link.include?(broadcast.broadcast_id) } }
  end

  def initialize(game, cutoff: nil, include_hidden: false)
    @game = game
    @cutoff = cutoff
    @include_hidden = include_hidden
    @names = PublicPersonRefs.new(game)
  end

  def as_json(*)
    beste = best
    return { video_id: nil, calibrated: nil, scenes: [] } if beste.nil?

    { video_id: beste[0].broadcast_id, calibrated: beste[0].calibrated?, scenes: beste[1] }
  end

  # [Übertragung, Szenen] mit den meisten Szenen, oder nil. Gewählt wird nach
  # allen Szenen (siehe Kopf), gefiltert erst danach.
  def best
    gewaehlt = self.class.oeffentliche_uebertragungen(@game)
                   .map { |broadcast| [broadcast, scenes_for(broadcast)] }
                   .max_by { |_broadcast, scenes| scenes.size }
    return nil if gewaehlt.nil?

    broadcast, szenen = gewaehlt
    [broadcast, szenen.reject { |_scene, shot, anker| versteckt?(anker, shot) }.map(&:first)]
  end

  private

  # [[Szene, GameShot, Anker], …] aller Szenen innerhalb der Aufzeichnung,
  # nach Start sortiert.
  def scenes_for(broadcast)
    timeline = StreamTimeline.new(@game, broadcast)
    tore = timeline.goals.select(&:shot?).filter_map do |goal|
      shot = goal_shots[goal.event[:event_id].to_i]
      fenster = timeline.scene(goal.anchor_at)
      fenster && [editor_felder(goal_json(goal.event, *fenster), shot), shot, goal.anchor_at]
    end
    marken = timeline.marks.filter_map do |mark|
      fenster = timeline.scene(mark.anchor_at)
      fenster && [editor_felder(mark_json(mark.shot, *fenster), mark.shot), mark.shot, mark.anchor_at]
    end
    (tore + marken).sort_by { |scene, _shot, _anker| scene[:start] }
  end

  def versteckt?(anchor_at, shot)
    return true if @cutoff && anchor_at >= @cutoff

    !@include_hidden && shot && !shot.in_highlights
  end

  # event_id => verknüpfter Tor-Schuss. Nur Schüsse, wie StreamTimeline.
  def goal_shots
    @goal_shots ||= @game.game_shots.shots.linked.where(result: 'goal').index_by(&:event_id)
  end

  # Kennung und Auswahl braucht nur der Editor; öffentlich bleibt die
  # client_uuid, der Schreibschlüssel des Tablets, draußen.
  def editor_felder(json, shot)
    return json unless @include_hidden

    json.merge(client_uuid: shot.client_uuid, in_highlights: shot.in_highlights, anchor_at: shot.tapped_at)
  end

  def mark_json(shot, start, ende)
    {
      kind: 'mark',
      event_id: nil,
      start: start,
      end: ende,
      team: shot.team,
      period: shot.period,
      game_time: shot.game_time.to_s
    }
  end

  def goal_json(event, start, ende)
    team = event[:event_team].to_s
    {
      kind: 'goal',
      event_id: event[:event_id].to_i,
      start: start,
      end: ende,
      team: team,
      home_goals: event[:home_goals].to_i,
      guest_goals: event[:guest_goals].to_i,
      period: event[:period].to_i,
      game_time: event[:time].to_s,
      scorer: @names.ref_by_number(team, event[:number]),
      assist: @names.ref_by_number(team, event[:assist])
    }
  end
end
