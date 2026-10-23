# lib/tasks/referees_merge_duplicates.rake
#
# Fuehrt eine von Hand gepruefte Liste von Schiri-Dubletten zusammen. Master wird
# jeweils das Profil mit der kleinsten Schiedsrichternummer (Referee.merge_roles),
# die Stammdaten kommen vom Profil mit der spaetesten Lizenz (Referee#merge_into!).
# Aendert sich fuer jemanden dadurch die Nummer, bekommt die Person eine Mail mit
# der neuen Nummer und, falls vorhanden, dem neuen Login sr-<Nummer>.
#
# Die Liste steht NICHT im Repo (Namen, Geburtsdaten), sondern kommt als CSV mit
# Semikolon und Kopfzeile:
#
#   ids;vorname;nachname;geburtsdatum;lizenzstufe
#   7956 9156 22258;Kurt;Nörlich;2010-11-21;
#   5319 6269;;;;L2
#
# - ids: Referee-IDs einer Person, mit Leerzeichen getrennt (zwei oder mehr)
# - vorname/nachname/geburtsdatum: optional, die richtigen Werte. Sie werden VOR dem
#   Zusammenfuehren an alle Profile der Gruppe geschrieben, damit der Master sie
#   unabhaengig davon traegt, welches Profil die Stammdaten liefert, und damit die
#   Nummern-Mail schon den richtigen Namen nennt.
# - lizenzstufe: optional, wird NACH dem Zusammenfuehren am Master gesetzt.
#
# Vorschau ohne Schreiben:
#   docker cp liste.csv saisonmanager_rails_api:/tmp/schiri-dubletten.csv
#   docker exec -e DRY_RUN=1 -e FILE=/tmp/schiri-dubletten.csv -e ADMIN_USER_ID=32 \
#     saisonmanager_rails_api bundle exec rake referees:merge_duplicates RAILS_ENV=production
require 'csv'

namespace :referees do
  desc 'Gepruefte Schiri-Dubletten aus FILE zusammenfuehren, kleinste Nummer wird Master (DRY_RUN=1 fuer Vorschau)'
  task merge_duplicates: :environment do
    dry_run = ENV['DRY_RUN'].present?
    path = ENV.fetch('FILE') { abort 'FILE=<pfad zur CSV> fehlt' }
    user_id = ENV['ADMIN_USER_ID'].presence&.to_i
    abort "User #{user_id} nicht gefunden" if user_id && !User.exists?(user_id)

    puts "== Schiri-Dubletten zusammenfuehren#{' (DRY RUN, es wird nichts geschrieben)' if dry_run} =="

    rows = CSV.read(path, col_sep: ';', headers: true, encoding: 'bom|utf-8')
    zaehler = Hash.new(0)

    rows.each_with_index do |row, index|
      zeile = index + 2
      ids = row['ids'].to_s.split.map(&:to_i).uniq
      profiles = Referee.where(id: ids).to_a
      if ids.size < 2 || profiles.size != ids.size
        puts "  Zeile #{zeile}: IDs #{row['ids'].inspect} unvollstaendig oder unbekannt -- uebersprungen"
        zaehler[:uebersprungen] += 1
        next
      end
      if profiles.any? { |r| r.merged_into_id.present? }
        puts "  Zeile #{zeile}: #{ids.join(', ')} enthaelt ein bereits zusammengefuehrtes Profil -- uebersprungen"
        zaehler[:uebersprungen] += 1
        next
      end

      stammdaten = {
        vorname: row['vorname'].presence&.strip,
        nachname: row['nachname'].presence&.strip,
        geburtsdatum: row['geburtsdatum'].presence && Date.iso8601(row['geburtsdatum'].strip)
      }.compact
      lizenzstufe = row['lizenzstufe'].presence&.strip

      # Dieselbe Rollenregel wie in der Maske, paarweise ueber die Gruppe gefaltet.
      master = profiles.reduce { |current, other| Referee.merge_roles(current, other).first }
      # Spaeteste Lizenz zuerst: Diese Dublette liefert die Stammdaten (merge_into!),
      # danach ist der Master auf ihrem Stand und alle weiteren sind aelter. So geht
      # die Nummern-Mail nur fuer das Profil raus, unter dem die Person heute laeuft,
      # und nicht auch fuer ein Zwischenprofil einer Dreiergruppe.
      secondaries = (profiles - [master]).sort_by do |r|
        [r.lizenzstufe.present? && r.gueltigkeit ? r.gueltigkeit : Date.new(0), -r.id]
      end.reverse
      aktuell = secondaries.first.send(:_license_newer_than?, master) ? secondaries.first : master

      puts "  Zeile #{zeile}: Master ##{master.id} (Nr. #{master.lizenznummer}) <- " \
           "#{secondaries.map { |r| "##{r.id} (Nr. #{r.lizenznummer})" }.join(', ')}"
      puts "    Stammdaten vom Profil ##{aktuell.id}: #{aktuell.nachname}, #{aktuell.vorname}"
      puts "    Korrektur vorher an allen Profilen: #{stammdaten.map { |k, v| "#{k}=#{v}" }.join(', ')}" if stammdaten.any?
      puts "    Lizenzstufe danach: #{lizenzstufe}" if lizenzstufe
      if aktuell != master && aktuell.lizenznummer.present? && master.lizenznummer.present? &&
         aktuell.lizenznummer != master.lizenznummer
        konto = aktuell.user
        puts "    Nummer aendert sich: #{aktuell.lizenznummer} -> #{master.lizenznummer}, " \
             "Konto: #{konto ? "#{konto.user_name} -> sr-#{master.lizenznummer}" : 'keins'}, " \
             "Mail: #{RefereeNotification.reachable?(aktuell) ? aktuell.email : 'nicht erreichbar'}"
        zaehler[:nummernwechsel] += 1
      end

      zaehler[:gruppen] += 1
      zaehler[:profile] += secondaries.size
      next if dry_run

      profiles.each { |r| r.update_columns(stammdaten.merge(updated_at: Time.current)) } if stammdaten.any?
      secondaries.each { |secondary| secondary.reload.merge_into!(master.reload, user_id) }
      master.reload.update_columns(lizenzstufe: lizenzstufe, updated_at: Time.current) if lizenzstufe
    rescue StandardError => e
      puts "  Zeile #{zeile}: FEHLER #{e.class}: #{e.message} -- Gruppe pruefen"
      zaehler[:fehler] += 1
    end

    puts "Ergebnis: #{zaehler[:gruppen]} Gruppe(n), #{zaehler[:profile]} Dublette(n), " \
         "#{zaehler[:nummernwechsel]} Nummernwechsel, #{zaehler[:uebersprungen]} uebersprungen, " \
         "#{zaehler[:fehler]} Fehler#{dry_run ? ' -- DRY RUN, nichts geschrieben' : ''}"
  end
end
