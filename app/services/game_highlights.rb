# frozen_string_literal: true

# Virtuelle Highlights eines Tablet-Spiels (fe#555): je Tor mit verknüpftem
# Schuss eine Szene in der YouTube-Aufzeichnung, ohne ein Video zu schneiden.
#
# Nur Tore mit Tablet-Schuss: `added_at` liegt 1,5 bis 2 min hinter dem Tor
# (Stichprobe vom 11.10.2026) und taugt für eine 20-Sekunden-Szene nicht.
#
# KEINE LIVE-ABFRAGE BEI YOUTUBE: Start und Länge der Aufzeichnung stammen aus
# `stream_broadcasts` (gespeichert vom Wächter, StreamChapters). Die Rechnung
# selbst steht in StreamTimeline#scene, dieselbe Stelle wie für die
# Sprungmarken.
#
# Nur verlinkte Übertragungen (siehe #oeffentliche_uebertragungen). Hat ein
# Spiel mehrere (Neustart nach einem Abbruch), gilt die mit den meisten Szenen. `video_id` ist nil, solange keine Übertragung mit
# bekanntem Start existiert; dann gibt es auch keine Szenen.
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

  def initialize(game, cutoff: nil)
    @game = game
    @cutoff = cutoff
    @names = PublicPersonRefs.new(game)
  end

  def as_json(*)
    beste = oeffentliche_uebertragungen.map { |broadcast| [broadcast, scenes_for(broadcast)] }
                                       .max_by { |_broadcast, scenes| scenes.size }
    return { video_id: nil, scenes: [] } if beste.nil?

    { video_id: beste[0].broadcast_id, scenes: beste[1] }
  end

  private

  # Nur Übertragungen, die das Spiel selbst verlinkt (`live_stream_link`,
  # `vod_link`). Eine nicht gelistete Aufzeichnung (Probelauf, Zusage an den
  # Verein, noch nicht freigegeben) steht dort nicht; ihre ID herauszugeben
  # hieße, sie öffentlich zu machen. Dieselbe Grenze wie
  # StreamWatchdog#verlinke_aufzeichnung, das den Link erst beim
  # Veröffentlichen setzt.
  def oeffentliche_uebertragungen
    links = [@game.live_stream_link, @game.vod_link].compact_blank
    return [] if links.empty?

    StreamBroadcast.where(game_id: @game.id).where.not(actual_start_at: nil)
                   .order(actual_start_at: :desc)
                   .select { |broadcast| links.any? { |link| link.include?(broadcast.broadcast_id) } }
  end

  def scenes_for(broadcast)
    timeline = StreamTimeline.new(@game, broadcast)
    szenen = timeline.goals.select(&:shot?).filter_map do |goal|
      next if @cutoff && goal.anchor_at >= @cutoff

      fenster = timeline.scene(goal.anchor_at)
      fenster && scene_json(goal.event, *fenster)
    end
    szenen.sort_by { |scene| scene[:start] }
  end

  def scene_json(event, start, ende)
    team = event[:event_team].to_s
    {
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
