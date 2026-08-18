# lib/tasks/report_double_home_clubs.rake
#
# Listet die Profile, bei denen mehr als eine Heimat-Zugehoerigkeit offen ist.
#
# Bewusst nur ein Bericht und kein Reparaturlauf: In allen 238 Faellen des Bestands
# (Stand 18.08.2026) stehen dort ZWEI VERSCHIEDENE Vereine, kein einziger ist eine
# Dublette desselben Vereins. Welcher der richtige ist, steht in den Daten nicht --
# ein Skript, das einen davon schliesst, raet.
#
# Seit api#479 richtet der Widerspruch keinen Schaden mehr an: Alle Leser gehen ueber
# Player#home_club_entry und meinen damit denselben Verein (den letzten offenen).
# Vorher nahm der Transferantrag den ersten, die Oberflaeche den letzten.
#
#   bundle exec rails players:report_double_home_clubs
#   bundle exec rails players:report_double_home_clubs CSV=/tmp/doppelte_heimatvereine.csv

namespace :players do
  desc 'Profile mit mehr als einer offenen Heimat-Zugehoerigkeit auflisten (nur lesend).'
  task report_double_home_clubs: :environment do
    require 'csv'

    rows = []

    Player.where(merged_into_id: nil).find_each do |player|
      offen = Array(player.clubs).select do |c|
        c.is_a?(Hash) &&
          ActiveModel::Type::Boolean.new.cast(c['home_club']) &&
          c['valid_until'].blank?
      end
      next if offen.size < 2

      massgeblich = offen.last['club_id']
      offen.each do |c|
        rows << {
          player_id: player.id,
          name: "#{player.first_name} #{player.last_name}",
          club_id: c['club_id'],
          club: Club.find_by(id: c['club_id'])&.name,
          created_at: c['created_at'],
          created_by: c['created_by'],
          massgeblich: c['club_id'] == massgeblich ? 'ja' : 'nein'
        }
      end
    end

    betroffene = rows.map { |r| r[:player_id] }.uniq.size
    puts "#{betroffene} Profile mit mehr als einer offenen Heimat-Zugehoerigkeit."
    puts 'Massgeblich ist jeweils der letzte Eintrag – so liest ihn Player#home_club_entry.'
    puts

    rows.group_by { |r| r[:player_id] }.each do |id, eintraege|
      puts "##{id} #{eintraege.first[:name]}"
      eintraege.each do |r|
        puts "   #{r[:massgeblich] == 'ja' ? '->' : '  '} #{r[:club]} (club_id=#{r[:club_id]}, " \
             "angelegt #{r[:created_at].presence || 'ohne Datum'} von #{r[:created_by].presence || 'Import'})"
      end
    end

    next if ENV['CSV'].blank?

    CSV.open(ENV['CSV'], 'w') do |csv|
      csv << rows.first.keys
      rows.each { |r| csv << r.values }
    end
    puts "\nCSV geschrieben: #{ENV['CSV']}"
  end
end
