# frozen_string_literal: true

# Beendet laufende YouTube-Übertragungen, die niemand mehr beendet hat.
#
# WOFÜR: Die Bundesliga-Livestreams laufen über den Verbandskanal. Am Ende eines
# Spiels schaltet der Verein seine Software ab, die Übertragung selbst bleibt
# aber "live" stehen -- YouTube merkt von sich aus nur, dass kein Bild mehr
# ankommt. Beendet wurden sie deshalb abends von Hand. Wird eine vergessen,
# blockiert sie den Streamschlüssel für das nächste Spiel und die Aufzeichnung
# bleibt unfertig.
#
# DIE REGEL: Beendet wird, wenn seit 15 Minuten kein Signal mehr anliegt UND der
# Spielbericht geschlossen ist. Beides zusammen, und das ist der Kern: Ein
# Signalabriss allein ist kein Spielende -- er passiert in der Drittelpause, bei
# einem Netzausfall in der Halle, beim Umstecken einer Kamera. Wer allein danach
# abschaltet, beendet die Übertragung mitten im Spiel, und zurückholen lässt sie
# sich nicht. Der geschlossene Spielbericht ist die Gegenprobe aus dem eigenen
# Haus: Er sagt, dass das Spiel wirklich vorbei ist.
#
# ZWEI AUSNAHMEN VON DER REGEL:
#
# 1. ÜBERGABE. Startet in weniger als 15 Minuten ein weiteres Heimspiel
#    derselben Mannschaft, muss die laufende Übertragung weg, egal was der
#    Spielbericht sagt -- ein Streamschlüssel trägt immer nur eine Übertragung,
#    sonst kommt das nächste Spiel gar nicht erst auf Sendung.
#
# 2. NOTABSCHALTUNG nach drei Stunden ohne Signal. Ohne sie hinge eine
#    Übertragung tagelang, wenn der Spielbericht nie geschlossen wird (vergessen,
#    Spielabbruch, Übertragung ohne Spiel wie der Tagesstream einer Deutschen
#    Meisterschaft). Drei Stunden liegen sicher hinter jedem Spielende, ein
#    laufendes Spiel kann sie nicht auslösen.
#
# Die Zuordnung Übertragung → Spiel läuft über den Streamschlüssel: YouTube sagt,
# welcher Schlüssel an der Übertragung hängt, `teams.stream_key` sagt, welcher
# Mannschaft er gehört, und deren heute AUSGERICHTETER Spieltag trägt das
# gesuchte Spiel. Ausrichter und Heimmannschaft sind nicht dasselbe -- siehe
# #spiel_fuer. Findet sich kein Spiel, greift nur die Notabschaltung.
class StreamWatchdog
  # Wie lange ohne Signal, bevor ein geschlossener Spielbericht zum Abschalten
  # führt.
  SIGNAL_TIMEOUT = 15.minutes
  # Wie kurz vor dem nächsten Spiel auf demselben Schlüssel übergeben wird.
  HANDOVER_LEAD = 15.minutes
  # Notabschaltung, wenn kein Spielbericht die Lage klärt.
  ABANDONED_AFTER = 3.hours
  # Wie weit zurück ein Spiel als "das hier laufende" gelten kann. Deckt Anwurf,
  # Verlängerung und Siegerehrung ab, ohne das Spiel vom Vortag einzufangen.
  GAME_LOOKBACK = 12.hours

  attr_reader :notes

  def initialize(api: nil, dry_run: false, now: Time.current)
    @api = api || YoutubeLiveApi.new
    @dry_run = dry_run
    @now = now
    @notes = []
  end

  # Liefert eine Zusammenfassung für die Ausgabe des Rake-Tasks.
  def run
    aktive = @api.active_broadcasts
    verschwunden = schliesse_verschwundene(aktive.map { |b| b[:id] })

    return zusammenfassung(0, [], verschwunden) if aktive.empty?

    zustaende = @api.streams(aktive.filter_map { |b| b[:stream_id] })
    beendet = aktive.filter_map { |broadcast| pruefe(broadcast, zustaende) }

    zusammenfassung(aktive.size, beendet, verschwunden)
  end

  private

  # Eine einzelne Übertragung. Gibt den Beendigungsgrund zurück, wenn beendet
  # wurde, sonst nil.
  def pruefe(broadcast, zustaende)
    satz = satz_fuer(broadcast)
    zustand = zustaende[broadcast[:stream_id]]

    if broadcast[:stream_id].blank? || zustand.nil?
      # Ohne gebundenen Stream gibt es kein Signal zu messen. Nichts tun ist hier
      # richtig: Das ist kein Zustand, den der Watchdog durch Abschalten
      # verbessert.
      notiz("#{broadcast[:title]}: kein gebundener Stream, übersprungen")
      return nil
    end

    teams = zustand[:key].present? ? Team.where(stream_key: zustand[:key]).to_a : []
    spiel = spiel_fuer(teams)
    satz.game_id = spiel&.id

    if uebergabe_faellig?(teams)
      return beende(satz, broadcast, 'das nächste Spiel auf demselben Streamschlüssel startet gleich')
    end

    if zustand[:status] == 'active'
      notiz("#{broadcast[:title]}: Signal liegt an") if satz.signal_lost_at.present?
      satz.assign_attributes(last_active_at: @now, signal_lost_at: nil)
      satz.save!
      return nil
    end

    ohne_signal(satz, broadcast, spiel, zustand)
  end

  def ohne_signal(satz, broadcast, spiel, zustand)
    satz.signal_lost_at ||= @now
    satz.save!

    minuten = (satz.offline_for(@now) / 60).round

    if minuten >= SIGNAL_TIMEOUT.in_minutes && spiel&.match_record_closed?
      return beende(satz, broadcast, "Spielbericht geschlossen, seit #{minuten} min kein Signal")
    end

    if minuten >= ABANDONED_AFTER.in_minutes
      grund = spiel ? 'Spielbericht weiterhin offen' : 'kein Spiel zugeordnet'
      return beende(satz, broadcast, "Notabschaltung: seit #{minuten} min kein Signal, #{grund}")
    end

    notiz("#{broadcast[:title]}: seit #{minuten} min kein Signal " \
          "(streamStatus=#{zustand[:status]}, Spielbericht #{berichtslage(spiel)})")
    nil
  end

  def berichtslage(spiel)
    return 'ohne Spiel' if spiel.nil?

    spiel.match_record_closed? ? 'geschlossen' : 'offen'
  end

  def beende(satz, broadcast, grund)
    if @dry_run
      notiz("[Probelauf] würde beenden: #{broadcast[:title]} -- #{grund}")
      return nil
    end

    @api.complete!(broadcast[:id])
    satz.assign_attributes(ended_at: @now, ended_reason: grund, signal_lost_at: nil)
    satz.save!
    { title: broadcast[:title], broadcast_id: broadcast[:id], reason: grund }
  rescue YoutubeLiveApi::Error => e
    # Ein Fehlschlag beim Beenden darf den Lauf nicht abbrechen: Die übrigen
    # Übertragungen sind davon unabhängig, und der nächste Lauf kommt in fünf
    # Minuten wieder. Der Satz bleibt offen, damit er es erneut versucht.
    notiz("FEHLER beim Beenden von #{broadcast[:title]}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    nil
  end

  # Das Spiel, das gerade läuft oder eben gelaufen ist.
  #
  # DER SCHLÜSSEL GEHÖRT DEM AUSRICHTER, NICHT DER HEIMMANNSCHAFT. Gesendet wird
  # aus der Halle, und wer die Halle stellt, stellt die Technik -- das ist meist,
  # aber nicht immer die Heimmannschaft. Richtet ein Verein einen Spieltag mit
  # mehreren Partien aus, laufen sie alle nacheinander über seinen einen
  # Schlüssel, auch die, in denen er selbst nicht Heim ist. Über die
  # Heimmannschaft zu suchen fände dort das falsche Spiel oder gar keines.
  #
  # Ausrichter eines Spieltags ist `game_days.club_id`; zusammen mit
  # `game_days.league_id` ist das genau eine Mannschaft, und an der hängt der
  # Schlüssel. Ein Spielverbund richtet über einen seiner Vereine aus, deshalb
  # zählt `syndicate_clubs` mit.
  #
  # Gesucht ist dann das jüngste Spiel dieses Spieltags, dessen Anwurf hinter uns
  # liegt. Bleibt es mehrdeutig, wird nichts zugeordnet und es greift allein die
  # Notabschaltung -- lieber eine Übertragung zu lange als die falsche zu früh
  # beendet.
  def spiel_fuer(teams)
    kandidaten = spiele_des_tages(teams, [tag_heute, tag_heute - 1]).select do |spiel|
      anwurf = spiel.start_date
      anwurf && anwurf <= @now && (@now - anwurf) < GAME_LOOKBACK
    end
    return nil if kandidaten.empty?

    if kandidaten.map(&:game_day_id).uniq.size > 1
      notiz('Streamschlüssel trifft heute auf mehrere Spieltage -- keine Zuordnung')
      return nil
    end

    kandidaten.max_by(&:start_date)
  end

  # Ein Ausrichter mit mehreren Partien an einem Tag ist der Regelfall, nicht die
  # Ausnahme: Sie laufen nacheinander über denselben Schlüssel, und jede braucht
  # eine eigene Übertragung. Die vorherige muss weg, bevor die nächste anfängt.
  def uebergabe_faellig?(teams)
    spiele_des_tages(teams, [tag_heute]).any? do |spiel|
      anwurf = spiel.start_date
      anwurf && anwurf > @now && anwurf <= @now + HANDOVER_LEAD
    end
  end

  def spiele_des_tages(teams, tage)
    spieltage = spieltage_der_ausrichter(teams, tage)
    return [] if spieltage.empty?

    Game.where(game_day_id: spieltage.map(&:id)).preload(:game_day).to_a
  end

  def spieltage_der_ausrichter(teams, tage)
    return [] if teams.blank?

    GameDay.where(date: tage.map(&:to_s), league_id: teams.map(&:league_id).uniq)
           .to_a
           .select { |spieltag| teams.any? { |team| richtet_aus?(team, spieltag) } }
  end

  def richtet_aus?(team, spieltag)
    return false unless team.league_id == spieltag.league_id

    team.club_id == spieltag.club_id || team.syndicate_clubs.to_a.include?(spieltag.club_id)
  end

  # Übertragungen, die YouTube nicht mehr als laufend führt: von Hand beendet,
  # oder von YouTube selbst abgeräumt. Ohne diesen Schritt bliebe ihr Satz für
  # immer offen und der Timer liefe gegen eine Übertragung, die es nicht mehr gibt.
  def schliesse_verschwundene(aktive_ids)
    veraltet = StreamBroadcast.running.where.not(broadcast_id: aktive_ids)
    veraltet.map do |satz|
      satz.update!(ended_at: @now, ended_reason: 'auf YouTube nicht mehr aktiv')
      satz.title
    end
  end

  def satz_fuer(broadcast)
    satz = StreamBroadcast.find_or_initialize_by(broadcast_id: broadcast[:id])
    satz.assign_attributes(title: broadcast[:title], stream_id: broadcast[:stream_id])
    # Ein Satz, der schon einmal als beendet markiert war und wieder auftaucht,
    # fängt von vorn an -- sonst stünde der alte Timer gegen die neue Sendung.
    satz.assign_attributes(ended_at: nil, ended_reason: nil) if satz.ended?
    satz.save!
    satz
  end

  def tag_heute
    @now.in_time_zone(Game::ICAL_TIMEZONE).to_date
  end

  def notiz(text)
    @notes << text
  end

  def zusammenfassung(aktiv, beendet, verschwunden)
    { active: aktiv, ended: beendet, closed_stale: verschwunden, notes: @notes, dry_run: @dry_run }
  end
end
