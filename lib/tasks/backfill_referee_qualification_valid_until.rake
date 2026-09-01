# lib/tasks/backfill_referee_qualification_valid_until.rake
#
# Traegt fuer Zusatzqualifikationen ohne Ablaufdatum (`referee_qualifications.valid_until
# IS NULL`) ein Zieldatum nach.
#
# Anlass: api#585 macht die Gueltigkeit zum Pflichtfeld. Das trifft nicht nur neue
# Eintraege. `Admin::RefereesController#sync_qualifications` setzt die Qualifikationen
# beim Speichern komplett neu (destroy_all + create), und das Bearbeiten-Formular
# schickt immer alle Zeilen mit -- eine Bestandszeile ohne Datum wuerde ab der
# Auslieferung also jedes Speichern dieses Schiedsrichters abweisen, auch eine reine
# Namensaenderung. Deshalb laeuft dieser Lauf VOR der Auslieferung von api#585.
#
# Zweite Wirkung, die den Lauf nicht bloss aufraeumend macht: `Referee.coach_qualified`
# las ein leeres valid_until bisher als „unbefristet" und laesst es mit api#585 nicht
# mehr mitzaehlen. Wer eine „B…"-Qualifikation ohne Datum trug, verliert damit die
# Beobachterberechtigung -- er steht nicht mehr in `available_coaches` der Ansetzung und
# nicht mehr in `RefereeObservationPolicy`. Der Lauf ist das, was diesen Verlust
# verhindert; ohne ihn faellt die Gruppe still kleiner aus.
#
# Das Zieldatum wird bewusst NICHT geraten. VALID_UNTIL ist Pflicht, weil jede Vorgabe
# hier eine fachliche Aussage waere: ein zu frueher Wert nimmt Berechtigungen, ein zu
# spaeter verlaengert sie. Der Wert gehoert von der RSK gesetzt.
#
# Dry-Run (Standard) -- zaehlt und listet den Bestand, schreibt nichts. Damit ist auch
# die Frage aus api#585 beantwortet, wie viele Zeilen betroffen sind:
#   bundle exec rails referees:backfill_qualification_valid_until
# Ausfuehren:
#   bundle exec rails referees:backfill_qualification_valid_until \
#     VALID_UNTIL=30.06.2027 DRY_RUN=false
#
# Auf Produktion:
#   docker exec saisonmanager_rails_api bundle exec rake \
#     referees:backfill_qualification_valid_until RAILS_ENV=production

namespace :referees do
  desc 'Zusatzqualifikationen ohne Ablaufdatum auf VALID_UNTIL setzen (api#585). DRY_RUN=false zum Ausfuehren.'
  task backfill_qualification_valid_until: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    # Im Dry-Run ohne VALID_UNTIL: Der Lauf dient dann nur der Bestandsaufnahme.
    # Erst das Schreiben verlangt das Datum -- so laesst sich zaehlen, bevor die
    # RSK sich auf einen Wert festgelegt hat.
    ziel = nil
    if ENV['VALID_UNTIL'].present?
      begin
        ziel = Date.strptime(ENV['VALID_UNTIL'], '%d.%m.%Y')
      rescue Date::Error
        abort "VALID_UNTIL=#{ENV['VALID_UNTIL'].inspect} ist kein Datum im Format TT.MM.JJJJ"
      end
    end
    abort 'VALID_UNTIL=TT.MM.JJJJ ist zum Schreiben Pflicht (kein Standardwert, siehe Kopfkommentar)' if ziel.nil? && !dry_run

    # Ein Zieldatum in der Vergangenheit erfuellt das Pflichtfeld, nimmt aber
    # jedem Betroffenen die Qualifikation (coach_qualified vergleicht >= heute).
    # Das kann gewollt sein, darf aber nicht versehentlich passieren.
    if ziel && ziel < Date.current && ENV['ALLOW_PAST'] != 'true'
      abort "VALID_UNTIL #{I18n.l(ziel)} liegt in der Vergangenheit -- die Qualifikation gilt danach " \
            'als abgelaufen. Wenn das gewollt ist: ALLOW_PAST=true'
    end

    offen = RefereeQualification.where(valid_until: nil)
                                .includes(:referee, :referee_qualification_type)
                                .order(:referee_id)

    puts "=== Zusatzqualifikationen ohne Gueltigkeit #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Bestand: #{RefereeQualification.count} Zusatzqualifikationen, davon #{offen.count} ohne Ablaufdatum"
    puts "Zieldatum: #{ziel ? I18n.l(ziel) : '(keins angegeben -- nur Bestandsaufnahme)'}"
    puts

    if offen.empty?
      puts 'Nichts zu tun -- kein Eintrag ohne Ablaufdatum.'
      next
    end

    # Nach Qualifikationsart gruppiert ausgeben: „B…" ist die Gruppe, die mit
    # api#585 eine Berechtigung verliert (siehe Kopfkommentar), und genau die
    # soll beim Lesen der Liste ins Auge fallen.
    je_art = offen.group_by { |q| q.referee_qualification_type&.name.to_s }
    je_art.sort_by { |name, _| name.downcase }.each do |name, zeilen|
      coach_hinweis = name.start_with?('B') ? '  << verliert ohne Datum die Beobachterberechtigung' : ''
      puts "#{name.presence || '(Qualifikationsart nicht gefunden)'}: #{zeilen.size}#{coach_hinweis}"
      zeilen.each do |q|
        r = q.referee
        kennung = r ? "#{r.lizenznummer} #{r.vorname} #{r.nachname}" : "Schiedsrichter ##{q.referee_id} nicht gefunden"
        puts "  ##{q.id} #{kennung}"
      end
    end
    puts

    if dry_run
      puts "#{offen.count} Eintraege waeren auf " \
           "#{ziel ? I18n.l(ziel) : 'ein noch zu bestimmendes Datum'} zu setzen."
      puts 'Dry-Run -- nichts geschrieben. Mit VALID_UNTIL=TT.MM.JJJJ DRY_RUN=false ausfuehren.'
      next
    end

    # `update_all` und nicht `update!`: Die Uniqueness-Validierung von
    # RefereeQualification wuerde je Zeile eine zusaetzliche Abfrage kosten, und
    # zu pruefen ist hier nichts -- der Lauf beruehrt ausschliesslich
    # `valid_until` und laesst das Paar (referee, Qualifikationsart) unangetastet.
    geschrieben = RefereeQualification.where(valid_until: nil).update_all(valid_until: ziel, updated_at: Time.current)

    verblieben = RefereeQualification.where(valid_until: nil).count
    puts "#{geschrieben} Eintraege auf #{I18n.l(ziel)} gesetzt, #{verblieben} weiterhin ohne Ablaufdatum."

    # Ein Rest waere ein Fehler des Laufs und nicht bloss eine Auslassung: Er
    # heisst, dass api#585 nach der Auslieferung genau diese Schiedsrichter im
    # Bearbeiten-Formular festhaelt.
    exit 1 if verblieben.positive?
  end
end
