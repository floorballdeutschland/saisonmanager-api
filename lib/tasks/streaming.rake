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
# laufenden zwei. Über den Tag sind das rund 600 der 10.000 Einheiten, die
# YouTube je Projekt und Tag gewährt. Das Beenden selbst kostet 50.
#
# Vorschau ohne Eingriff -- meldet, was er beenden würde, und beendet nichts:
#   docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake streaming:watchdog RAILS_ENV=production
namespace :streaming do
  desc 'Laufende YouTube-Übertragungen ohne Signal beenden, wenn der Spielbericht geschlossen ist'
  task watchdog: :environment do
    unless YoutubeLiveApi.configured?
      # Kein Abbruch mit Fehlercode: Auf Staging und in der Entwicklung ist der
      # fehlende Zugang der gewollte Zustand, und ein Cronjob, der dort jede
      # fünf Minuten einen Fehler meldet, wird irgendwann abgeschaltet -- auch
      # auf Produktion.
      puts 'YouTube-Zugang nicht eingerichtet (YOUTUBE_CLIENT_ID/_SECRET/_REFRESH_TOKEN), nichts zu tun.'
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
  end

  desc 'Streamschlüssel aus einer CSV (liga,mannschaft,streamschluessel) an den Mannschaften hinterlegen'
  task import_keys: :environment do
    pfad = ENV['CSV'].presence
    abort 'Aufruf: rake streaming:import_keys CSV=/pfad/zur/datei.csv [DRY_RUN=1]' if pfad.blank?
    abort "Datei nicht gefunden: #{pfad}" unless File.exist?(pfad)

    dry_run = ENV['DRY_RUN'].present?
    puts "Streamschlüssel aus #{pfad}#{dry_run ? ' (PROBELAUF)' : ''}"

    gesetzt = 0
    unveraendert = 0
    offen = []

    CSV.foreach(pfad, headers: true, col_sep: ',', encoding: 'bom|utf-8') do |zeile|
      liga = zeile['liga'].to_s.strip
      name = zeile['mannschaft'].to_s.strip
      key = zeile['streamschluessel'].to_s.strip
      next if name.blank? || key.blank?

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

      vorher = team.stream_key.present? ? ' (ersetzt einen vorhandenen)' : ''
      puts "  #{team.league&.name} / #{team.name} (#{team.id})#{vorher}"
      team.update!(stream_key: key) unless dry_run
      gesetzt += 1
    end

    puts "#{gesetzt} Schlüssel gesetzt, #{unveraendert} unverändert."
    next if offen.empty?

    puts "#{offen.size} Zeile(n) nicht zugeordnet -- von Hand prüfen:"
    offen.each { |eintrag| puts "  #{eintrag}" }
  end
end
