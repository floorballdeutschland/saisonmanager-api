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
  desc 'Lizenz und Kursergebnisse zusammengefuehrter Schiri-Profile auf den Master nachziehen (DRY_RUN=1 fuer Vorschau)'
  task fix_merge_leftovers: :environment do
    dry_run = ENV['DRY_RUN'].present?
    puts "== Schiri-Merge nacharbeiten#{' (DRY RUN, es wird nichts geschrieben)' if dry_run} =="

    secondaries = Referee.where.not(merged_into_id: nil).order(:id)
    puts "Zusammengefuehrte Profile: #{secondaries.count}"

    lizenz_korrekturen = 0
    kursergebnisse = 0

    secondaries.each do |secondary|
      master = Referee.find_by(id: secondary.merged_into_id)
      unless master
        puts "  ## #{secondary.id}: Master ##{secondary.merged_into_id} existiert nicht -- uebersprungen"
        next
      end

      vorher = [master.lizenzstufe, master.gueltigkeit]
      secondary.send(:_adopt_license_fields, master)
      nachher = [master.lizenzstufe, master.gueltigkeit]
      offene_kurse = RefereeCourseResult.where(referee_id: secondary.id).count

      if vorher != nachher
        lizenz_korrekturen += 1
        puts "  Master ##{master.id} #{master.nachname}, #{master.vorname}: " \
             "#{vorher[0] || '-'}/#{vorher[1] || '-'} -> #{nachher[0] || '-'}/#{nachher[1] || '-'} " \
             "(aus Dublette ##{secondary.id})"
      end
      if offene_kurse.positive?
        kursergebnisse += offene_kurse
        puts "  Master ##{master.id}: #{offene_kurse} Kursergebnis(se) von Dublette ##{secondary.id} umgehaengt"
      end

      next if dry_run

      ActiveRecord::Base.transaction do
        master.save!(validate: false) if vorher != nachher
        secondary.send(:_repoint_referee_records, master)
      end
    end

    puts "Ergebnis: #{lizenz_korrekturen} Lizenz(en) nachgezogen, #{kursergebnisse} Kursergebnis(se) umgehaengt" \
         "#{' -- DRY RUN, nichts geschrieben' if dry_run}"
  end
end
