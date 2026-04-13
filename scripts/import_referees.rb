# Rails runner script: Schiedsrichter aus CSV importieren
# Aufruf: bundle exec rails runner scripts/import_referees.rb
#
# Löscht alle bestehenden Einträge und importiert aus referees_import.csv.
# Die CSV ist Single Source of Truth (Schiedsrichterliste 2025).

require 'csv'

CSV_PATH = File.join(__dir__, '..', 'tmp', 'referees_import.csv')

unless File.exist?(CSV_PATH)
  puts "CSV nicht gefunden: #{CSV_PATH}"
  puts "Bitte referees_import.csv nach tmp/ kopieren."
  exit 1
end

puts "Lösche #{Referee.count} bestehende Einträge..."
Referee.delete_all

rows      = CSV.read(CSV_PATH, headers: true, encoding: 'UTF-8')
imported  = 0
errors    = []

rows.each do |row|
  referee = Referee.new(
    lizenznummer:      row['lizenznummer'].to_i,
    nachname:          row['nachname'].presence || '?',
    vorname:           row['vorname'].presence  || '?',
    geburtsdatum:      row['geburtsdatum'].presence,
    verein:            row['verein'].presence,
    lizenzstufe:       row['lizenzstufe'].presence,
    zusatzqualifikation: row['zusatzqualifikation'].presence,
    gueltigkeit:       row['gueltigkeit'].presence
  )

  if referee.save
    imported += 1
  else
    errors << "Nr #{row['lizenznummer']}: #{referee.errors.full_messages.join(', ')}"
  end
end

puts "Import abgeschlossen: #{imported} Schiedsrichter importiert."
puts "Fehler: #{errors.size}"
errors.first(10).each { |e| puts "  #{e}" }
