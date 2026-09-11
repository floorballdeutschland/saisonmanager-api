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
# 1. ÜBERGABE. Beginnt gleich eine weitere Partie desselben Ausrichters, muss die
#    laufende Übertragung weg -- ein Streamschlüssel trägt immer nur eine
#    Übertragung, sonst kommt die nächste gar nicht erst auf Sendung. Dieser Pfad
#    trägt dieselben Sicherungen wie die Hauptregel (siehe #uebergabe_faellig?);
#    ohne sie war er der gefährlichste Weg im ganzen Wächter.
#
# 2. NOTABSCHALTUNG nach drei Stunden ohne Signal. Ohne sie hinge eine
#    Übertragung tagelang, wenn der Spielbericht nie geschlossen wird (vergessen,
#    Spielabbruch, Übertragung ohne Spiel wie der Tagesstream einer Deutschen
#    Meisterschaft). Drei Stunden liegen sicher hinter jedem Spielende, ein
#    laufendes Spiel kann sie nicht auslösen.
#
# WELCHES SPIEL ZU EINER ÜBERTRAGUNG GEHÖRT, IST KEINE FRAGE DES RATENS. Wurde
# sie über den Streaming-Bereich angelegt, steht es in `StreamBroadcast#game_id`
# -- dort hat ein Mensch entschieden. Nur für Übertragungen, die daran vorbei
# entstanden sind (der Tagesstream einer Meisterschaft, das alte Python-Skript),
# wird über den Streamschlüssel und den ausgerichteten Spieltag geschlossen. Und
# wo dieser Schluss mehrdeutig bleibt, unterbleibt er: Lieber eine Übertragung zu
# lange als die falsche zu früh beendet.
class StreamWatchdog
  # Wie lange ohne Signal, bevor ein geschlossener Spielbericht zum Abschalten
  # führt.
  SIGNAL_TIMEOUT = 15.minutes
  # Wie weit vor und nach dem Anwurf der nächsten Partie übergeben wird. Auch
  # nach hinten, weil ein verspäteter Anwurf sonst nie zur Übergabe führte und
  # der Schlüssel bis zur Notabschaltung blockiert bliebe.
  HANDOVER_LEAD = 15.minutes
  # Notabschaltung, wenn kein Spielbericht die Lage klärt.
  ABANDONED_AFTER = 3.hours
  # Wie weit zurück ein Spiel als "das hier laufende" gelten kann. Deckt Anwurf,
  # Verlängerung und Siegerehrung ab. Bewusst kürzer als ein halber Tag: Bei
  # zwölf Stunden wäre ein gestriges 22:00-Spiel heute um 9 Uhr noch Kandidat,
  # und ein Morgenstream auf demselben Schlüssel bekäme den geschlossenen
  # Spielbericht von gestern zugeordnet.
  GAME_LOOKBACK = 8.hours

  # Wie lange eine "nicht gelistete" Uebertragung nach dem Ende so bleibt, bevor
  # sie oeffentlich wird (siehe #veroeffentliche_faellige).
  #
  # Nicht null: Der Ausrichter sendet parallel selbst, und sein Programm endet
  # nicht mit dem Schlusspfiff -- Interviews, Abmoderation. Waehrend er noch
  # live ist, darf unsere Aufzeichnung nicht oeffentlich danebenstehen; genau
  # das ist die Zusage. Drei Stunden sind der Abstand, auf den sich der Verband
  # festgelegt hat: am Spieltagabend oeffentlich, aber nicht neben dem laufenden
  # Stream.
  PROMOTE_DELAY = 3.hours

  attr_reader :notes, :probleme

  def initialize(api: nil, dry_run: false, now: Time.current)
    @api = api || YoutubeLiveApi.new
    @dry_run = dry_run
    @now = now
    @notes = []
    # Was einen Menschen erreichen muss. Der Rake-Task endet damit mit einem
    # Fehlercode und meldet nach Sentry -- eine Logzeile unter dreihundert
    # anderen erreicht niemanden.
    @probleme = []
  end

  # Liefert eine Zusammenfassung für die Ausgabe des Rake-Tasks.
  def run
    aktive = @api.active_broadcasts
    verschwunden = schliesse_verschwundene(aktive.map { |b| b[:id] })
    # Vor der Pruefung der laufenden Uebertragungen, und unabhaengig davon, ob
    # ueberhaupt eine laeuft: Faellig wird die Veroeffentlichung Stunden nach dem
    # Ende, also typischerweise in einem Lauf, in dem nichts mehr sendet. Stuende
    # sie hinter dem `return` unten, liefe sie an einem ruhigen Abend nie.
    veroeffentlicht = veroeffentliche_faellige

    return zusammenfassung(0, [], verschwunden, veroeffentlicht) if aktive.empty?

    zustaende, ohne_antwort = @api.streams_mit_luecken(aktive.filter_map { |b| b[:stream_id] })
    melde_luecken(aktive, ohne_antwort)

    beendet = []
    aktive.each do |broadcast|
      ergebnis = pruefe(broadcast, zustaende)
      beendet << ergebnis if ergebnis
    rescue YoutubeLiveApi::QuotaExceeded => e
      # Ein erschöpftes Kontingent ist ein Zustand, kein Einzelereignis: Jeder
      # weitere Abschaltversuch kostet 50 Einheiten und scheitert genauso.
      problem("Kontingent erschöpft, Lauf abgebrochen: #{e.message}")
      break
    end

    zusammenfassung(aktive.size, beendet, verschwunden, veroeffentlicht)
  end

  private

  # Eine einzelne Übertragung. Gibt den Beendigungsgrund zurück, wenn beendet
  # wurde, sonst nil.
  def pruefe(broadcast, zustaende)
    satz = satz_fuer(broadcast)
    return nil if satz.nil?

    zustand = zustaende[broadcast[:stream_id]]

    if broadcast[:stream_id].blank?
      # Ohne gebundenen Stream gibt es kein Signal zu messen -- weder die
      # 15-Minuten-Regel noch die Notabschaltung könnten je greifen, denn beide
      # hängen am Signalverlust. Die Übertragung stünde sonst für immer "live"
      # und produzierte alle fünf Minuten eine Logzeile, die niemand liest:
      # genau der Zustand, gegen den dieser Wächter existiert.
      #
      # Deshalb zählt hier die Zeit seit der Anlage. Nach der Notfrist wird
      # abgeschaltet, vorher gemeldet -- eine Übertragung ohne Bindung empfängt
      # ohnehin nie ein Bild.
      alter = satz.created_at ? @now - satz.created_at : 0
      if alter >= ABANDONED_AFTER
        return beende(satz, broadcast,
                      "Notabschaltung: seit #{(alter / 3600).floor} h ohne gebundenen Stream")
      end

      problem("#{broadcast[:title]}: kein gebundener Stream -- sie empfängt kein Bild")
      return nil
    end

    if zustand.nil? || zustand[:status].blank?
      # Die Sammelmeldung in `melde_luecken` nennt diese Übertragung schon.
      # Zweimal zu melden macht aus einem Problem zwei und lässt die Zahl im
      # Bericht doppelt so hoch aussehen, wie die Lage ist.
      #
      # GEBUNDEN, ABER UNBEKANNT -- ein anderer Fall als "kein Signal". Die
      # Übertragung hängt an einem Stream, über dessen Zustand die Schnittstelle
      # nichts sagt (gelöschte Ressource, Teilantwort, fehlendes Recht). Daraus
      # "kein Signal" zu machen hiesse, auf Unwissen hin unwiderruflich
      # abzuschalten. Der Timer läuft deshalb nicht -- aber es bleibt auch nicht
      # still: Der Lauf meldet es als Problem.
      notiz("#{broadcast[:title]}: Stream gebunden, Zustand nicht abrufbar -- kein Timer")
      return nil
    end

    teams = zustand[:key].present? ? Team.where(stream_key: zustand[:key]).to_a : []
    spiel = spiel_von(satz, teams)
    # Die gemeldete Zuordnung wird NIE überschrieben -- schon gar nicht mit nil.
    # Sie stammt aus dem Streaming-Bereich, wo ein Mensch die Übertragung für
    # genau dieses Spiel angelegt hat; die Heuristik hier ist nur der Rückfall.
    satz.game_id ||= spiel&.id

    signal_aktiv = zustand[:status] == 'active'

    if uebergabe_faellig?(teams, satz, spiel, signal_aktiv)
      return beende(satz, broadcast, 'die nächste Partie desselben Ausrichters beginnt')
    end

    if signal_aktiv
      notiz("#{broadcast[:title]}: Signal liegt an") if satz.signal_lost_at.present?
      satz.assign_attributes(last_active_at: @now, signal_lost_at: nil)
      speichern(satz)
      return nil
    end

    ohne_signal(satz, broadcast, spiel, zustand)
  end

  def ohne_signal(satz, broadcast, spiel, zustand)
    satz.signal_lost_at ||= @now
    speichern(satz)

    offline = @now - satz.signal_lost_at
    minuten = (offline / 60).floor

    # Auf die Sekunde und nicht auf gerundete Minuten: `.round` machte aus der
    # dokumentierten Regel "seit 15 Minuten" faktisch "seit 14 Minuten 30".
    if offline >= SIGNAL_TIMEOUT && spiel&.match_record_closed?
      return beende(satz, broadcast, "Spielbericht geschlossen, seit #{minuten} min kein Signal")
    end

    if offline >= ABANDONED_AFTER
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

  # Beendet die Übertragung -- der einzige unwiderrufliche Schritt im ganzen
  # Wächter.
  #
  # DER BELEG WIRD VOR DER HANDLUNG GESCHRIEBEN. Zwischen `complete!` und dem
  # Speichern liegt eine Datenbankverbindung; bricht sie danach weg, wäre die
  # Übertragung bei YouTube beendet und der Grund für immer verloren -- und die
  # Migration begründet diese Tabelle ausdrücklich damit, dass dieser Beleg
  # existieren muss. `ended_at` wird erst danach gesetzt: Solange es fehlt, gilt
  # der Satz als laufend und ein gescheiterter Versuch wird beim nächsten Lauf
  # wiederholt.
  def beende(satz, broadcast, grund)
    if @dry_run
      notiz("[Probelauf] würde beenden: #{broadcast[:title]} -- #{grund}")
      return nil
    end

    satz.update!(ended_reason: grund)
    @api.complete!(broadcast[:id])
    satz.update!(ended_at: @now, signal_lost_at: nil)

    { title: broadcast[:title], broadcast_id: broadcast[:id], reason: grund }
  rescue YoutubeLiveApi::Error, ActiveRecord::ActiveRecordError => e
    # Ein Fehlschlag beim Beenden darf den Lauf nicht abbrechen: Die übrigen
    # Übertragungen sind davon unabhängig, und der nächste Lauf kommt in fünf
    # Minuten. Der Satz bleibt offen, damit er es erneut versucht.
    problem("Beenden von #{broadcast[:title]} fehlgeschlagen: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    nil
  end

  # Das Spiel, zu dem diese Übertragung gehört.
  #
  # Erst die gemeldete Zuordnung, dann -- und nur dann -- die Heuristik über den
  # Streamschlüssel.
  def spiel_von(satz, teams)
    gemeldet = satz.game_id ? Game.find_by(id: satz.game_id) : nil
    return gemeldet if gemeldet

    spiel_fuer(teams)
  end

  # Das jüngste Spiel des ausgerichteten Spieltags, dessen Anwurf hinter uns
  # liegt.
  #
  # DER SCHLÜSSEL GEHÖRT DEM AUSRICHTER, NICHT DER HEIMMANNSCHAFT. Gesendet wird
  # aus der Halle, und wer die Halle stellt, stellt die Technik. Wer ausrichtet,
  # beantwortet GameDay#hosting_team -- die eine Stelle, an der diese Frage
  # beantwortet wird.
  #
  # Drei Lagen führen bewusst zu "keine Zuordnung", weil in ihnen nichts bekannt
  # ist und ein geratenes Spiel schlimmer wäre als gar keines:
  #   * der Schlüssel trifft heute mehrere Spieltage,
  #   * auf dem Spieltag fehlt bei einer Partie die Anwurfzeit (dann wäre das
  #     jüngste Spiel mit Anwurf womöglich das vorherige -- mit geschlossenem
  #     Bericht, während die Übertragung des laufenden sendet),
  #   * kein Spiel liegt im Rückblick.
  def spiel_fuer(teams)
    spieltage = spieltage_der_ausrichter(teams, [tag_heute, tag_heute - 1])
    return nil if spieltage.empty?

    # ERST der Zeitfilter, DANN die Mehrdeutigkeit. Andersherum sperrte ein
    # Ausrichter mit Heimspieltag am Samstag UND am Sonntag die Zuordnung den
    # ganzen Sonntag -- in der Bundesliga der Regelfall, nicht die Ausnahme. Der
    # Vortag wird nur wegen der Übertragungen nach Mitternacht mitgeführt; nach
    # dem Zeitfilter ist er tagsüber ohnehin leer.
    kandidaten = spiele_von(spieltage).select do |spiel|
      anwurf = spiel.start_date
      anwurf && anwurf <= @now && (@now - anwurf) < GAME_LOOKBACK
    end
    return nil if kandidaten.empty?

    if kandidaten.map(&:game_day_id).uniq.size > 1
      notiz('Streamschlüssel trifft mehrere Spieltage -- keine Zuordnung')
      return nil
    end

    # Eine Partie ohne Anwurfzeit auf DEMSELBEN Spieltag macht "das jüngste
    # Spiel" unbrauchbar: Das wäre womöglich das vorherige -- mit geschlossenem
    # Bericht, während die Übertragung des laufenden sendet.
    geschwister = spiele_von(spieltage).select { |spiel| spiel.game_day_id == kandidaten.first.game_day_id }
    if geschwister.any? { |spiel| spiel.start_date.nil? }
      notiz('Spieltag enthält eine Partie ohne Anwurfzeit -- keine Zuordnung')
      return nil
    end

    kandidaten.max_by(&:start_date)
  end

  # Ein Ausrichter mit mehreren Partien an einem Tag ist der Regelfall, nicht die
  # Ausnahme: Sie laufen nacheinander über denselben Schlüssel, und jede braucht
  # eine eigene Übertragung. Die vorherige muss weg, bevor die nächste anfängt.
  #
  # DREI SICHERUNGEN, die dieser Pfad ursprünglich nicht hatte und die ihn zum
  # gefährlichsten Weg im Wächter machten:
  #
  #   1. Mehrdeutigkeit sperrt, genau wie bei der Zuordnung. Sonst reichte es,
  #      dass irgendeine Mannschaft mit demselben Schlüssel irgendwo anwirft.
  #   2. Gehört die laufende Übertragung selbst zu der Partie, die gleich
  #      beginnt, ist das Vorlauf und keine Übergabe -- wer den Stream eine
  #      Viertelstunde vor Anwurf startet (Kameracheck, Einlaufmusik), verlor ihn
  #      sonst fünf Minuten vor dem Anpfiff.
  #   3. Liegt Signal an und ist der Bericht des laufenden Spiels nicht
  #      geschlossen, wird nicht übergeben: Verglichen wird der PAPIERANWURF der
  #      nächsten Partie, und eine Verlängerung im laufenden Spiel darf keine
  #      sendende Übertragung kappen. Das kann den Schlüssel blockieren -- dann
  #      steht das im Problembericht, statt dass mitten im Spiel abgeschaltet
  #      wird.
  def uebergabe_faellig?(teams, satz, spiel, signal_aktiv)
    spieltage = spieltage_der_ausrichter(teams, [tag_heute])
    return false if spieltage.empty?

    if spieltage.size > 1
      notiz('Streamschlüssel trifft mehrere Spieltage -- keine Übergabe')
      return false
    end

    # Die eigene Partie zählt nicht als Nachfolger: Wer den Stream mit Vorlauf
    # startet, verlöre ihn sonst kurz vor dem Anpfiff. Ohne bekannte Zuordnung
    # lässt sich das nicht auseinanderhalten -- dann wird gar nicht übergeben.
    if spiel.nil? && satz.game_id.nil?
      notiz("#{satz.title}: kein Spiel zugeordnet -- keine Übergabe")
      return false
    end

    andere = spiele_von(spieltage).reject do |kandidat|
      kandidat.id == spiel&.id || kandidat.id == satz.game_id
    end

    if andere.any? { |kandidat| kandidat.start_date.nil? }
      # Wie bei der Zuordnung: Ohne Anwurfzeit ist unbekannt, wann die nächste
      # Partie beginnt -- und auf Unwissen hin wird nicht abgeschaltet.
      notiz("#{satz.title}: Partie ohne Anwurfzeit auf dem Spieltag -- keine Übergabe")
      return false
    end

    # ZWEI VERSCHIEDENE FENSTER, und das ist der Kern dieser Methode:
    #
    #   * Der BERICHT schaut weit zurück. Ein Anwurf, der lange zurückliegt,
    #     während die alte Übertragung noch sendet, ist genau die Lage, die sonst
    #     vollständig verstummt: keine Übergabe, keine Notabschaltung (deren
    #     Timer läuft nur bei Signalverlust), keine Meldung -- der Schlüssel
    #     bliebe dauerhaft belegt, ohne dass es jemand erfährt.
    #   * Das ABSCHALTEN bleibt eng. Übergeben wird nur um den Anwurf herum;
    #     sonst risse eine Partie vom Nachmittag am Abend noch eine Sendung ab.
    naechster = andere.select { |kandidat| kandidat.start_date > @now - GAME_LOOKBACK }
                      .min_by(&:start_date)
    return false if naechster.nil?

    if signal_aktiv && !spiel&.match_record_closed?
      # NICHT abschalten, solange gesendet wird und das laufende Spiel nicht
      # abgeschlossen ist: Verglichen wird der Papieranwurf, und eine
      # Verlängerung darf keine sendende Übertragung kappen.
      verzug = ((@now - naechster.start_date) / 60).floor
      lage = verzug.negative? ? 'beginnt gleich' : "läuft seit #{verzug} min"
      problem("#{satz.title}: die nächste Partie #{lage}, aber die laufende Übertragung " \
              'sendet noch und ihr Spielbericht ist nicht geschlossen -- nicht übergeben')
      return false
    end

    naechster.start_date > @now - HANDOVER_LEAD &&
      naechster.start_date <= @now + HANDOVER_LEAD
  end

  def spiele_von(spieltage)
    return [] if spieltage.empty?

    Game.where(game_day_id: spieltage.map(&:id)).preload(:game_day).to_a
  end

  # Wer ausrichtet, beantwortet GameDay#hosting_team -- und nur die. Die Regel
  # hier ein zweites Mal hinzuschreiben (Verein gleich, Spielverbund mitzählen)
  # liefe irgendwann auseinander, und der Unterschied fiele erst auf, wenn der
  # Wächter die falsche Übertragung beendet.
  def spieltage_der_ausrichter(teams, tage)
    return [] if teams.blank?

    team_ids = teams.map(&:id)
    GameDay.where(date: tage.map(&:to_s), league_id: teams.map(&:league_id).uniq)
           .to_a
           .select { |spieltag| team_ids.include?(spieltag.hosting_team&.id) }
  end

  # Übertragungen, die YouTube nicht mehr als laufend führt: von Hand beendet,
  # oder von YouTube selbst abgeräumt.
  #
  # DREI EINSCHRÄNKUNGEN, ohne die das mehr kaputt macht als es aufräumt:
  #
  #   * Nur Sätze, die schon einmal Signal hatten -- oder deren Anlage lange
  #     genug zurückliegt. Eine im Voraus angelegte Übertragung ist bei YouTube
  #     `ready`, nicht `active`; ohne die erste Bedingung bekäme jeder eine Woche
  #     vorher eingerichtete Stream fünf Minuten später ein `ended_at` und stünde
  #     im Streaming-Bereich als "beendet", bevor er je gelaufen ist. Ohne die
  #     zweite bliebe eine Übertragung, deren `active`-Zustand der Wächter nie
  #     erwischt hat (Cron-Ausfall, Deploy, sehr kurze Sendung), für immer offen.
  #   * Erst nach SIGNAL_TIMEOUT ohne Signal. Eine formal erfolgreiche
  #     Leerantwort (200 ohne `items`) schlösse sonst schlagartig alle laufenden
  #     Sätze.
  #   * Nicht im Probelauf. "Meldet, was er beenden würde, und beendet nichts"
  #     gilt auch für das Buchhalterische.
  def schliesse_verschwundene(aktive_ids)
    return [] if @dry_run

    # `ended_reason: nil` ist der Kern: Ein Satz, dessen Grund schon steht, hat
    # `beende` durchlaufen -- `complete!` war erfolgreich, nur das abschließende
    # Speichern scheiterte. Ohne diese Bedingung überschriebe die Buchhaltung
    # genau den Beleg, für den `beende` seine Reihenfolge umdreht, und machte
    # den Satz nebenbei wiederbelebbar.
    veraltet = StreamBroadcast.running
                              .where(ended_reason: nil)
                              .where('COALESCE(last_active_at, created_at) < ?', @now - ABANDONED_AFTER)
                              .or(
                                StreamBroadcast.running
                                               .where(ended_reason: nil)
                                               .where.not(last_active_at: nil)
                                               .where('last_active_at < ?', @now - SIGNAL_TIMEOUT)
                              )
                              .where.not(broadcast_id: aktive_ids)
    veraltet.map do |satz|
      satz.update!(ended_at: @now, ended_reason: 'auf YouTube nicht mehr aktiv')
      satz.title
    end
  end

  # Der Satz zu einer laufenden Übertragung, oder nil, wenn er nicht angefasst
  # werden darf.
  #
  # Ein Satz, den der Wächter selbst beendet hat, wird NICHT wiederbelebt: Sein
  # `ended_reason` ist der einzige Beleg dafür, warum unwiderruflich abgeschaltet
  # wurde, und die Transition zu `complete` ist bei YouTube nicht sofort sichtbar
  # -- der nächste Lauf sähe die Übertragung sonst wieder als aktiv und
  # überschriebe den Beleg. Rein buchhalterisch geschlossene Sätze
  # ("auf YouTube nicht mehr aktiv") dürfen dagegen zurückkommen.
  BOOKKEEPING_REASON = 'auf YouTube nicht mehr aktiv'

  # Nicht gelistete Uebertragungen, deren Zusage-Frist abgelaufen ist, auf
  # oeffentlich stellen.
  #
  # Der Ausloeser ist `ended_at` und nicht die Anwurfzeit: Was zaehlt, ist das
  # Ende der SENDUNG. Eine Verlaengerung, ein spaeter Anwurf oder ein
  # Tagesstream verschieben es, und die Zusage haengt am parallelen Senden, nicht
  # am Spielplan.
  #
  # `promote_to_public` ist der Riegel: Veroeffentlicht wird nur, was wegen einer
  # Zusage nicht gelistet ist. Eine Aufzeichnung, die jemand aus einem anderen
  # Grund nicht gelistet hat -- Probelauf, interne Aufnahme -- bleibt, wie sie
  # ist. Heuristisch "alles Nichtgelistete nach drei Stunden oeffentlich" waere
  # ein oeffentlich gestelltes Video, das nie oeffentlich werden sollte, und das
  # ist nicht zurueckzunehmen.
  def veroeffentliche_faellige
    faellig = StreamBroadcast.where(promote_to_public: true, promoted_at: nil)
                             .where.not(ended_at: nil)
                             .where(ended_at: ..(@now - PROMOTE_DELAY))

    faellig.find_each.filter_map { |satz| veroeffentliche(satz) }
  end

  def veroeffentliche(satz)
    if @dry_run
      notiz("[Probelauf] wuerde veroeffentlichen: #{satz.broadcast_id}")
      return { broadcast_id: satz.broadcast_id, result: 'dry_run' }
    end

    ergebnis = @api.publish!(satz.broadcast_id)
    # Auch `:verschwunden` wird abgehakt: Die Uebertragung gibt es nicht mehr,
    # ein zweiter Versuch aendert daran nichts. Ohne den Stempel liefe der
    # Cronjob alle fuenf Minuten in dieselbe leere Antwort.
    satz.update!(promoted_at: @now)
    verlinkt = verlinke_aufzeichnung(satz) unless ergebnis == :verschwunden
    notiz("veroeffentlicht (#{ergebnis}#{verlinkt ? ', im Spielplan verlinkt' : ''}): #{satz.broadcast_id}")
    { broadcast_id: satz.broadcast_id, result: ergebnis.to_s, linked: verlinkt || false }
  rescue YoutubeLiveApi::Error => e
    # Kein Stempel: Ein Netzfehler oder ein erschoepftes Kontingent ist
    # voruebergehend, und die Veroeffentlichung soll im naechsten Lauf erneut
    # versucht werden. Gemeldet wird sie trotzdem -- eine Zusage, die still
    # nicht eingeloest wird, faellt sonst niemandem auf.
    problem("Veroeffentlichung fehlgeschlagen (#{satz.broadcast_id}): #{e.class} #{e.message}")
    nil
  end

  # Den Link der jetzt oeffentlichen Aufzeichnung in den Spielplan schreiben.
  #
  # HIER UND NICHT NUR BEIM ANLEGEN: `Admin::StreamingController#link_setzen`
  # schreibt den Link ausdruecklich NUR fuer oeffentliche Uebertragungen -- ein
  # nicht gelisteter Link waere fuer Zuschauer tot. Bei einer Zusage ist die
  # Uebertragung aber genau deshalb nicht gelistet, der Link bliebe also fuer
  # immer aus, und die Aufzeichnung waere zwar oeffentlich, aber ueber den
  # Spielplan nicht zu finden. Das ist die zweite Haelfte der Zusage: live nicht
  # parallel, danach bei uns auffindbar.
  #
  # Nur auf ein leeres Feld: Steht dort schon etwas, hat es jemand von Hand
  # gesetzt oder ein zweiter Lauf war schneller. Ein Ueberschreiben nimmt dem
  # Spielplan einen Link, den jemand bewusst dorthin gestellt hat.
  def verlinke_aufzeichnung(satz)
    spiel = satz.game
    return false if spiel.nil? || spiel.live_stream_link.present?

    # `update!` wie im Controller, damit `flush_league_caches` laeuft -- sonst
    # steht der Link in der Datenbank, im oeffentlichen Spielplan aber erst nach
    # Ablauf des Zwischenspeichers.
    spiel.update!(live_stream_link: "https://www.youtube.com/watch?v=#{satz.broadcast_id}")
    true
  end

  def satz_fuer(broadcast)
    satz = StreamBroadcast.find_or_initialize_by(broadcast_id: broadcast[:id])
    satz.assign_attributes(title: broadcast[:title], stream_id: broadcast[:stream_id])

    if satz.ended?
      if satz.ended_reason == BOOKKEEPING_REASON
        satz.assign_attributes(ended_at: nil, ended_reason: nil)
      else
        # KARENZ, sonst meldet der Normalfall einen Fehler: Die Transition zu
        # `complete` ist bei YouTube nicht sofort sichtbar, der nächste Lauf
        # kommt aber in fünf Minuten. Ohne diese Frist erzeugte JEDE saubere
        # Abschaltung ein Sentry-Ereignis und eine Cron-Fehlermail -- und nach
        # zwei Wochen schaltet jemand den Alarm ab.
        if satz.ended_at && satz.ended_at > @now - SIGNAL_TIMEOUT
          notiz("#{broadcast[:title]}: eben beendet, bei YouTube noch als aktiv geführt")
        else
          problem("#{broadcast[:title]}: wurde am #{satz.ended_at} beendet " \
                  "(#{satz.ended_reason}), läuft bei YouTube aber wieder")
        end
        return nil
      end
    end

    speichern(satz)
    satz
  end

  # Im Probelauf wird nichts geschrieben -- auch kein Timer.
  def speichern(satz)
    satz.save! unless @dry_run
  end

  def melde_luecken(aktive, ohne_antwort)
    return if ohne_antwort.empty?

    titel = aktive.select { |b| ohne_antwort.include?(b[:stream_id]) }.map { |b| b[:title] }
    problem("Zu #{ohne_antwort.size} gebundenen Stream(s) kam kein Zustand zurück: #{titel.join(', ')}")
  end

  def tag_heute
    @now.in_time_zone(Game::ICAL_TIMEZONE).to_date
  end

  def notiz(text)
    @notes << text
  end

  # Ein Problem ist eine Notiz, die jemanden erreichen muss.
  #
  # Im Probelauf bleibt es eine Notiz: "meldet, was er tun würde, und tut nichts"
  # gilt auch für Sentry und den Fehlercode -- sonst wäre eine Vorschau nicht
  # folgenlos, und in einer Pipeline endete sie rot.
  def problem(text)
    @notes << "PROBLEM: #{text}"
    @probleme << text unless @dry_run
  end

  def zusammenfassung(aktiv, beendet, verschwunden, veroeffentlicht = [])
    { active: aktiv, ended: beendet, closed_stale: verschwunden,
      published: veroeffentlicht,
      notes: @notes, problems: @probleme, dry_run: @dry_run }
  end
end
