# frozen_string_literal: true

require 'csv'

# Der Watchdog für die Livestreams des Verbandskanals.
#
# MUSS per Cron laufen, sonst greift er nie. Alle fünf Minuten, rund um die Uhr:
#
#   */5 * * * * docker exec saisonmanager_rails_api bundle exec rake streaming:watchdog RAILS_ENV=production >> /var/log/streaming-watchdog.log 2>&1
#
# Anders als beim wöchentlichen Lizenzlistenversand spielt die Zeitzone hier
# keine Rolle -- ein Fünf-Minuten-Takt trifft jede Stunde, in Winter- wie in
# Sommerzeit. Die Zuordnung zum Spiel rechnet trotzdem im Kalender des
# Spielbetriebs (Europe/Berlin), nicht in der Zone des Servers (UTC).
#
# Kontingent: Ein Lauf ohne laufende Übertragung kostet eine Einheit, mit
# laufenden zwei. Über den Tag sind das bis zu 600 der 10.000 Einheiten, die
# YouTube je Projekt und Tag gewährt (nachts ohne Übertragung entsprechend
# weniger). Das Beenden selbst kostet 50.
#
# Vorschau ohne Eingriff -- meldet, was er beenden würde, und beendet nichts:
#   docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake streaming:watchdog RAILS_ENV=production
namespace :streaming do
  desc 'Laufende YouTube-Übertragungen ohne Signal beenden, wenn der Spielbericht geschlossen ist'
  task watchdog: :environment do
    unless YoutubeLiveApi.configured?
      meldung = 'YouTube-Zugang nicht eingerichtet (YOUTUBE_CLIENT_ID/_SECRET/_REFRESH_TOKEN)'

      # AUF PRODUKTION IST DAS EIN AUSFALL, sonst der Normalzustand.
      #
      # Auf Staging und in der Entwicklung soll der Zugang fehlen -- ein Cronjob,
      # der dort alle fünf Minuten einen Fehler meldet, wird irgendwann
      # abgeschaltet, und dann auch auf Produktion. Auf Produktion dagegen heißt
      # ein fehlender Zugang: Ab jetzt wird keine einzige Übertragung mehr
      # beendet, also genau der Zustand, den dieser Task abschaffen soll. Fällt
      # eine Variable bei einem Neustart weg, sähe das ohne diesen Zweig
      # wochenlang aus wie Normalbetrieb.
      if Rails.env.production?
        Sentry.capture_message("#{meldung} -- der Livestream-Wächter läuft leer") if defined?(Sentry)
        Sentry.close if defined?(Sentry)
        abort "#{meldung}, auf Produktion ist das ein Ausfall."
      end

      puts "#{meldung}, nichts zu tun."
      next
    end

    dry_run = ENV['DRY_RUN'].present?
    watchdog = StreamWatchdog.new(dry_run: dry_run)

    begin
      ergebnis = watchdog.run
    rescue YoutubeLiveApi::Error => e
      # Sichtbar scheitern: Kontingent erschöpft oder Token widerrufen heißt,
      # dass ab jetzt keine Übertragung mehr beendet wird. Das darf nicht als
      # stiller Fehlschlag im Log verschwinden.
      Sentry.capture_exception(e) if defined?(Sentry)
      # `Sentry.close` VOR `abort`: Der Versand läuft über einen Hintergrund-
      # Faden, und `abort` beendet den Prozess sofort. In einem kurzlebigen
      # Rake-Lauf verpufft das Ereignis sonst -- der einzige laute Pfad des
      # Wächters wäre damit ebenfalls still.
      Sentry.close if defined?(Sentry)
      abort "Watchdog abgebrochen: #{e.message}"
    end

    zeit = Time.current.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M')
    puts "[#{zeit}] #{ergebnis[:active]} laufende Übertragung(en)#{' (PROBELAUF)' if dry_run}"

    ergebnis[:notes].each { |note| puts "  #{note}" }

    ergebnis[:closed_stale].each do |titel|
      puts "  abgeschlossen (nicht mehr aktiv): #{titel}"
    end

    ergebnis[:ended].each do |beendet|
      puts "  BEENDET: #{beendet[:title]} -- #{beendet[:reason]}"
    end

    # Probleme erreichen einen Menschen, statt in einer Logdatei zu versinken,
    # die alle fünf Minuten um mehrere Zeilen wächst. Der Cronjob meldet damit
    # einen Fehlercode, und Sentry bekommt eine Meldung -- ein hängengebliebener
    # Stream ist sonst erst zu bemerken, wenn ein Verein anruft, weil sein
    # Schlüssel belegt ist.
    next if ergebnis[:problems].blank?

    if defined?(Sentry)
      Sentry.capture_message("Livestream-Wächter: #{ergebnis[:problems].join(' | ')}")
      Sentry.close
    end
    abort "#{ergebnis[:problems].size} Problem(e), siehe oben."
  end

  desc 'Streamschlüssel aus einer CSV (liga,mannschaft,streamschluessel) an den Mannschaften hinterlegen'
  task import_keys: :environment do
    pfad = ENV['CSV'].presence
    abort 'Aufruf: rake streaming:import_keys CSV=/pfad/zur/datei.csv [DRY_RUN=1]' if pfad.blank?
    abort "Datei nicht gefunden: #{pfad}" unless File.exist?(pfad)

    dry_run = ENV['DRY_RUN'].present?
    puts "Streamschlüssel aus #{pfad}#{dry_run ? ' (PROBELAUF)' : ''}"

    # Trennzeichen aus der Kopfzeile bestimmen. Die Quelle ist ein Excel-Blatt
    # der Spielbetriebskommission, und ein deutsches Excel exportiert mit
    # Semikolon. Mit fest verdrahtetem Komma wäre dann JEDE Spalte nil, jede
    # Zeile würde still übersprungen, und die Ausgabe lautete
    # "0 Schlüssel gesetzt, 0 unverändert" -- von einem echten "alles schon
    # aktuell" nicht zu unterscheiden. Für einen Task, der Geheimnisse einträgt,
    # ist das die schlechtestmögliche Rückmeldung.
    kopfzeile = File.open(pfad, 'r:bom|utf-8', &:readline)
    trenner = kopfzeile.count(';') > kopfzeile.count(',') ? ';' : ','

    pflicht = %w[mannschaft streamschluessel]
    spalten = CSV.parse_line(kopfzeile, col_sep: trenner).map { |feld| feld.to_s.strip.downcase }
    fehlend = pflicht - spalten
    abort "Fehlende Spalte(n) in der Kopfzeile: #{fehlend.join(', ')} (gefunden: #{spalten.join(', ')})" if fehlend.any?

    gesetzt = 0
    unveraendert = 0
    leer = 0
    offen = []

    CSV.foreach(pfad, headers: true, col_sep: trenner, encoding: 'bom|utf-8') do |zeile|
      liga = zeile['liga'].to_s.strip
      name = zeile['mannschaft'].to_s.strip
      key = zeile['streamschluessel'].to_s.strip
      if name.blank? || key.blank?
        leer += 1
        next
      end

      treffer = Team.current_season.where(name: name).to_a
      # Die Ligaspalte ist nur Beifang: Sie schärft, wenn ein Mannschaftsname in
      # mehreren Ligen der laufenden Saison vorkommt (die zweite Mannschaft eines
      # Vereins heißt oft genauso). Als alleiniges Kriterium taugt sie nicht --
      # die Schreibweisen der Tabelle sind nicht die der Ligennamen.
      if treffer.size > 1 && liga.present?
        geschaerft = treffer.select do |team|
          [team.league&.name, team.league&.short_name].compact.any? { |n| n.casecmp?(liga) }
        end
        treffer = geschaerft if geschaerft.any?
      end

      if treffer.empty?
        offen << "#{liga} / #{name}: keine Mannschaft der laufenden Saison gefunden"
        next
      end

      if treffer.size > 1
        offen << "#{liga} / #{name}: #{treffer.size} Mannschaften passen " \
                 "(#{treffer.map { |t| "#{t.id} in #{t.league&.name}" }.join(', ')})"
        next
      end

      team = treffer.first
      if team.stream_key == key
        unveraendert += 1
        next
      end

      # Beide folgenden Lagen sind fast immer ein Tippfehler in der Tabelle --
      # und leiten den Stream eines Vereins auf den Kanal eines anderen. Sie
      # gehören deshalb in die Prüfliste und nicht als Wort in den Fließtext.
      if team.stream_key.present?
        offen << "#{liga} / #{name}: trägt bereits einen anderen Schlüssel -- nicht ersetzt"
        next
      end

      doppelt = Team.where(stream_key: key).where.not(id: team.id).pluck(:id)
      if doppelt.any?
        offen << "#{liga} / #{name}: dieser Schlüssel hängt schon an Mannschaft #{doppelt.join(', ')} -- nicht gesetzt"
        next
      end

      puts "  #{team.league&.name} / #{team.name} (#{team.id})"
      team.update!(stream_key: key) unless dry_run
      gesetzt += 1
    end

    puts "#{gesetzt} Schlüssel gesetzt, #{unveraendert} unverändert, #{leer} Zeile(n) ohne Angaben."
    next if offen.empty?

    puts "#{offen.size} Zeile(n) nicht zugeordnet -- von Hand prüfen:"
    offen.each { |eintrag| puts "  #{eintrag}" }
    # Jede offene Zeile ist eine Mannschaft ohne Schlüssel -- also eine
    # Übertragung, die der Wächter später keinem Spiel zuordnen kann. Unter Cron
    # oder in einer Pipeline wäre Status 0 hier ein stiller Fehlschlag.
    abort "#{offen.size} Zeile(n) konnten nicht zugeordnet werden." unless dry_run
  end
end
