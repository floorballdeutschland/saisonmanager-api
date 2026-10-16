# frozen_string_literal: true

# Wo im Video ein Tor liegt.
#
# Die eine Stelle, an der aus einer Uhrzeit eine Sekunde in der Aufzeichnung
# wird. Sprungmarken in der Beschreibung (api#815) und virtuelle Highlights
# (fe#555) rechnen beide hier, damit sie nicht auseinanderlaufen.
#
# GERECHNET WIRD IN UHRZEIT, NICHT IN SPIELZEIT:
#
#   Position = Anker − actual_start_at − Vorlauf
#
# Dass der Stream vor dem Anpfiff beginnt und die Spielzeit effektiv läuft,
# spielt deshalb keine Rolle. Sekunde 0 ist `liveStreamingDetails.actualStartTime`
# der Übertragung.
#
# DER ANKER: `added_at` des Ereignisses, also der Zeitpunkt der Eingabe. Das Tor
# wird regelgemäß erst mit dem Bully eingetragen, dazu kommt die Ausfüllzeit;
# die Stichprobe vom 11.10.2026 (sechs Bundesligaspiele, 72 Tore) lag mit 30 s
# Vorlauf durchweg zu spät. 120 s landen zuverlässig vor dem Tor, dafür grob.
#
# GÜLTIG NUR INNERHALB DER AUFZEICHNUNG: 0 bis `vod_duration_seconds`. Die Länge
# stammt aus `contentDetails.duration` und ausdrücklich nicht aus
# `actualEndTime`: Das liegt durch die 15-Minuten-Regel des Wächters 15 min bis
# über zwei Stunden hinter dem Ende der Aufzeichnung.
class StreamTimeline
  # Vorlauf einer Sprungmarke, deren Anker die Eingabe des Tores ist.
  CHAPTER_LEAD_ADDED_AT = 120
  # Vorlauf einer Sprungmarke, deren Anker ein im Tabletmodus angetippter Schuss
  # ist (ab api#816).
  CHAPTER_LEAD_SHOT = 10

  Goal = Struct.new(:event, :anchor_at, :source, keyword_init: true) do
    def shot?
      source == :shot
    end
  end

  attr_reader :game, :broadcast

  def initialize(game, broadcast)
    @game = game
    @broadcast = broadcast
  end

  # Ohne Start und Länge gibt es keine Position. Beides kommt vom Wächter, und
  # zwar erst, wenn YouTube die Aufzeichnung fertig verarbeitet hat.
  def ready?
    broadcast.actual_start_at.present? && broadcast.vod_duration_seconds.to_i.positive?
  end

  # Die Tore des Spiels mit ihrem Anker, nach Anker sortiert. Tore ohne Anker
  # (Altdaten ohne `added_at`) fallen weg.
  #
  # Die Ereignisse kommen aus `formatted_events`, damit Torart, Spielstand und
  # Schütze genau so gelesen werden wie auf der öffentlichen Spielseite; der
  # Anker steht nur im Rohereignis.
  def goals
    @goals ||= begin
      roh = (game.events || []).index_by { |event| event['id'].to_i }
      game.formatted_events.filter_map do |event|
        next unless event[:event_type] == :goal

        anker = anchor_for(event, roh[event[:event_id].to_i])
        anker && Goal.new(event: event, anchor_at: anker[0], source: anker[1])
      end.sort_by(&:anchor_at)
    end
  end

  # Sekunde im Video für einen Anker, oder nil, wenn sie außerhalb der
  # Aufzeichnung liegt.
  def position(anchor_at, lead)
    return nil unless ready? && anchor_at

    sekunde = (anchor_at - broadcast.actual_start_at).floor - lead
    return nil if sekunde.negative? || sekunde > broadcast.vod_duration_seconds

    sekunde
  end

  # Vorlauf einer Sprungmarke für dieses Tor.
  def chapter_position(goal)
    position(goal.anchor_at, goal.shot? ? CHAPTER_LEAD_SHOT : CHAPTER_LEAD_ADDED_AT)
  end

  # 754 -> "12:34", 4321 -> "1:12:01". So erkennt YouTube Zeitangaben in der
  # Beschreibung als Sprungmarken.
  def self.timestamp(sekunden)
    stunden, rest = sekunden.to_i.divmod(3600)
    minuten, sek = rest.divmod(60)
    return format('%<m>d:%<s>02d', m: minuten, s: sek) if stunden.zero?

    format('%<h>d:%<m>02d:%<s>02d', h: stunden, m: minuten, s: sek)
  end

  private

  # [Zeitpunkt, Quelle] oder nil.
  def anchor_for(_event, roh)
    added_at = roh && roh['added_at']
    return nil if added_at.blank?

    [Time.zone.at(added_at.to_i), :added_at]
  end
end
