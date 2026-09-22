# lib/tasks/fix_referee_merge_leftovers.rake
#
# Holt nach, was frueher an einem zusammengefuehrten Schiedsrichter-Profil liegen
# geblieben ist: die Lizenz (Stufe + Gueltigkeit) und die Kursergebnisse, dazu
# Ansetzungen, Rueckmeldungen und Spieltagsbestaetigungen.
#
# Ursache: `Referee#merge_into!` uebernahm Lizenzstufe und Gueltigkeit nur, wenn das
# Feld am Master LEER war, und hing die genannten Datensaetze gar nicht um. Ein durch
# Kursimport unter neuem Namen (Heirat) angelegtes Zweitprofil traegt aber gerade die
# frische Lizenz -- sie blieb auf dem deaktivierten Profil zurueck, waehrend der Master
# seine alte, oft abgelaufene behielt. Der Code-Fix ist api#742; dieser Lauf raeumt auf,
# was bis dahin entstanden ist.
#
# ZUERST api#742 ausliefern, dann diesen Lauf: Der Lauf ruft genau die Methoden auf, die
# der Fix mitbringt.
#
# Vorschau ohne Schreiben:
#   docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake referees:fix_merge_leftovers RAILS_ENV=production
namespace :referees do
  # Folgt einer Merge-Kette bis zum letzten nicht zusammengefuehrten Profil.
  # `merge_into!` verbietet nur einen bereits zusammengefuehrten MASTER, A->B und
  # spaeter B->C sind also moeglich. Ohne diesen Schritt schriebe der Lauf die Lizenz
  # von A auf das tote B und erzeugte genau den Rest, den er beseitigen soll.
  def endgueltiger_master(referee)
    gesehen = [referee.id]
    aktuell = referee
    while aktuell.merged_into_id.present?
      naechster = Referee.find_by(id: aktuell.merged_into_id)
      return nil if naechster.nil? || gesehen.include?(naechster.id)

      gesehen << naechster.id
      aktuell = naechster
    end
    aktuell
  end

  desc 'Lizenz und Kursergebnisse zusammengefuehrter Schiri-Profile auf den Master nachziehen (DRY_RUN=1 fuer Vorschau)'
  task fix_merge_leftovers: :environment do
    dry_run = ENV['DRY_RUN'].present?
    puts "== Schiri-Merge nacharbeiten#{' (DRY RUN, es wird nichts geschrieben)' if dry_run} =="
    puts 'Umgehaengt werden Kursergebnisse, Ansetzungen, Rueckmeldungen und Spieltagsbestaetigungen;'
    puts 'bei offenen Kurszeilen wandert der Stammdaten-Schnappschuss auf den Master mit.'

    secondaries = Referee.where.not(merged_into_id: nil).order(:id)
    puts "Zusammengefuehrte Profile: #{secondaries.count}"

    lizenz_korrekturen = 0
    kursergebnisse = 0

    secondaries.each do |secondary|
      master = endgueltiger_master(secondary)
      if master.nil? || master.id == secondary.id
        puts "  ## #{secondary.id}: Master ##{secondary.merged_into_id} fehlt oder Kette ist zirkulaer -- uebersprungen"
        next
      end
      puts "  Kette ##{secondary.id} -> ##{master.id} (ueber #{secondary.merged_into_id})" if master.id != secondary.merged_into_id

      vorher = [master.lizenzstufe, master.gueltigkeit]
      secondary.send(:_adopt_license_fields, master)
      nachher = [master.lizenzstufe, master.gueltigkeit]
      lizenz_neu = vorher != nachher

      kurse = RefereeCourseResult.where(referee_id: secondary.id)
      kurse_offen = kurse.where.not(status: 'applied').count

      if lizenz_neu
        lizenz_korrekturen += 1
        puts "  Master ##{master.id} #{master.nachname}, #{master.vorname}: " \
             "#{vorher[0] || '-'}/#{vorher[1] || '-'} => #{nachher[0] || '-'}/#{nachher[1] || '-'} " \
             "(aus Dublette ##{secondary.id})"
      end
      if kurse.any?
        kursergebnisse += kurse.count
        puts "  Master ##{master.id}: #{kurse.count} Kursergebnis(se) (#{kurse_offen} davon offen) " \
             "von Dublette ##{secondary.id}#{dry_run ? ' umzuhaengen' : ' umgehaengt'}"
      end

      next if dry_run

      ActiveRecord::Base.transaction do
        master.save!(validate: false) if lizenz_neu
        secondary.send(:_repoint_referee_records, master)
      end
    end

    puts "Ergebnis: #{lizenz_korrekturen} Lizenz(en), #{kursergebnisse} Kursergebnis(se)" \
         "#{dry_run ? ' -- DRY RUN, nichts geschrieben' : ' geschrieben'}"
  end
end
