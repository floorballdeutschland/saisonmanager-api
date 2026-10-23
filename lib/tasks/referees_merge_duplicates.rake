# lib/tasks/referees_merge_duplicates.rake
#
# Fuehrt eine von Hand gepruefte Liste von Schiri-Dubletten zusammen. Master wird
# jeweils das Profil mit der kleinsten Schiedsrichternummer (Referee.merge_roles),
# die Stammdaten kommen vom Profil mit der spaetesten Lizenz (Referee#merge_into!).
# Aendert sich fuer jemanden dadurch die Nummer, bekommt die Person eine Mail mit
# der neuen Nummer und, falls vorhanden, dem Login.
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
#   Zusammenfuehren an alle noch lebenden Profile der Gruppe geschrieben, damit der
#   Master sie unabhaengig davon traegt, welches Profil die Stammdaten liefert, und
#   damit die Nummern-Mail schon den richtigen Namen nennt.
# - lizenzstufe: optional, wird NACH dem Zusammenfuehren am Master gesetzt.
#
# Wiederholbar: Ein zweiter Lauf mit derselben Liste fuehrt nur zusammen, was noch
# lebt, und setzt Korrekturen und Lizenzstufe erneut. Eine Gruppe, die beim ersten
# Lauf mittendrin abbrach, wird so fertig. Jede Zusammenlegung committet einzeln;
# eine Transaktion um die ganze Gruppe gibt es bewusst nicht, weil die Mails
# sofort (deliver_now) und erst nach dem jeweiligen Commit rausgehen.
#
# Vorschau ohne Schreiben:
#   docker cp liste.csv saisonmanager_rails_api:/tmp/schiri-dubletten.csv
#   docker exec -e DRY_RUN=1 -e FILE=/tmp/schiri-dubletten.csv -e ADMIN_USER_ID=32 \
#     saisonmanager_rails_api bundle exec rake referees:merge_duplicates RAILS_ENV=production
require 'csv'

namespace :referees do
  # Spaeteste Lizenz zuerst: Diese Dublette liefert die Stammdaten (merge_into!),
  # danach ist der Master auf ihrem Stand und alle weiteren sind aelter. So geht
  # die Nummern-Mail nur fuer das Profil raus, unter dem die Person heute laeuft,
  # und nicht auch fuer ein Zwischenprofil einer Dreiergruppe.
  def merge_duplicates_order(secondaries)
    secondaries.sort_by do |r|
      [r.lizenzstufe.present? && r.gueltigkeit ? r.gueltigkeit : Date.new(0), -r.id]
    end.reverse
  end

  def merge_duplicates_preview(master, secondary)
    plan = secondary.merge_account_plan(master)
    account = secondary.send(:_describe_account_plan, plan) || 'kein Konto'
    numbers_differ = secondary.lizenznummer.present? && master.lizenznummer.present? &&
                     secondary.lizenznummer != master.lizenznummer
    return "#{account}, keine Nummern-Mail" unless numbers_differ && secondary.send(:_license_newer_than?, master)

    mail = RefereeNotification.reachable?(secondary) ? secondary.email : 'nicht erreichbar'
    "Nummer #{secondary.lizenznummer} -> #{master.lizenznummer}, #{account}, Mail an #{mail}"
  end

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

      # Schon zusammengefuehrte Profile durch ihren Master ersetzen. Fuehren sie
      # nicht alle in diese Gruppe zurueck, gehoert eine ID zu einer anderen Person.
      live = profiles.map(&:canonical_profile)
      if live.any?(&:nil?)
        puts "  Zeile #{zeile}: Merge-Kette kaputt bei #{ids.join(', ')} -- uebersprungen"
        zaehler[:uebersprungen] += 1
        next
      end
      live.uniq!
      foreign = live.map(&:id) - ids
      if foreign.any?
        puts "  Zeile #{zeile}: Profil(e) #{foreign.join(', ')} gehoeren nicht zur Gruppe -- uebersprungen"
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
      master = live.reduce { |current, other| Referee.merge_roles(current, other).first }
      secondaries = merge_duplicates_order(live - [master])

      puts "  Zeile #{zeile}: Master ##{master.id} (Nr. #{master.lizenznummer})" \
           "#{' -- bereits zusammengefuehrt, nur Korrekturen' if secondaries.empty?}"
      puts "    Korrektur vorher: #{stammdaten.map { |k, v| "#{k}=#{v}" }.join(', ')}" if stammdaten.any?
      puts "    Lizenzstufe danach: #{lizenzstufe}" if lizenzstufe
      zaehler[:gruppen] += 1

      if dry_run
        # Die Vorschau sieht den Master vor jeder Zusammenlegung. Bei Dreiergruppen
        # gilt sie damit fuer die erste Dublette genau, fuer die weiteren nur
        # ungefaehr; die Mail geht nach der Reihenfolge ohnehin nur fuer die erste.
        secondaries.each do |secondary|
          puts "    <- ##{secondary.id} (Nr. #{secondary.lizenznummer}): #{merge_duplicates_preview(master, secondary)}"
        end
        zaehler[:profile] += secondaries.size
        next
      end

      live.each { |r| r.update_columns(stammdaten.merge(updated_at: Time.current)) } if stammdaten.any?
      secondaries.each do |secondary|
        outcome = secondary.reload.merge_into!(master.reload, user_id, deliver_now: true)
        zaehler[:profile] += 1
        zaehler[:"mail_#{outcome.mail}"] += 1 if outcome.mail
        puts "    <- ##{secondary.id} (Nr. #{secondary.lizenznummer}) zusammengefuehrt" \
             "#{", #{outcome.account}" if outcome.account}#{", Mail: #{outcome.mail}" if outcome.mail}"
      end
      master.reload.update_columns(lizenzstufe: lizenzstufe, updated_at: Time.current) if lizenzstufe
    rescue StandardError => e
      puts "  Zeile #{zeile}: FEHLER #{e.class}: #{e.message} -- die Zeilen darueber sind geschrieben, " \
           'Ursache beheben und den Lauf wiederholen'
      zaehler[:fehler] += 1
    end

    puts "Ergebnis: #{zaehler[:gruppen]} Gruppe(n), #{zaehler[:profile]} Dublette(n), " \
         "#{zaehler[:uebersprungen]} uebersprungen, #{zaehler[:fehler]} Fehler" \
         "#{dry_run ? ' -- DRY RUN, nichts geschrieben' : ''}"
    unless dry_run
      puts "Nummern-Mails: #{zaehler[:mail_sent]} verschickt, #{zaehler[:mail_unreachable]} ohne Adresse, " \
           "#{zaehler[:mail_failed]} FEHLGESCHLAGEN"
    end
  end
end
