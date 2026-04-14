# Rails runner script: Schiedsrichter-Lizenzdaten aus members.csv aktualisieren
# Aufruf: bundle exec rails runner scripts/update_referee_licenses.rb CSV_PATH=/path/to/members.csv
#
# Aktualisiert für bestehende Schiedsrichter (Match per Lizenznummer):
#   lizenzstufe, gueltigkeit, zusatzqualifikation, gueltigkeit_z, verein
# Legt KEINE neuen Einträge an (fehlende Namensfelder).

require 'csv'

csv_path = ENV['CSV_PATH'] || File.join(__dir__, '..', 'tmp', 'members.csv')

unless File.exist?(csv_path)
  puts "CSV nicht gefunden: #{csv_path}"
  exit 1
end

def parse_date(str)
  return nil if str.blank? || str.strip == '-'

  parts = str.strip.split('.')
  return nil unless parts.size == 3

  Date.new(parts[2].to_i, parts[1].to_i, parts[0].to_i)
rescue ArgumentError
  nil
end

rows = CSV.read(csv_path, headers: true, col_sep: ';', encoding: 'ISO-8859-1:UTF-8')

updated  = 0
skipped  = 0
not_found = 0

rows.each do |row|
  nr = row['Lizenznummer']&.to_i
  next unless nr&.positive?

  referee = Referee.find_by(lizenznummer: nr)

  unless referee
    not_found += 1
    next
  end

  zusatz = row['Zusatzqualifikation']&.strip
  zusatz = nil if zusatz.blank? || zusatz == '-'

  attrs = {
    lizenzstufe:          row['Lizenzstufe']&.strip.presence,
    gueltigkeit:          parse_date(row['Gueltigkeit']),
    zusatzqualifikation:  zusatz,
    gueltigkeit_z:        parse_date(row['GueltigkeitZ']),
    verein:               row['Verein']&.strip.presence
  }

  if referee.update(attrs)
    updated += 1
  else
    skipped += 1
    puts "  Fehler Nr #{nr}: #{referee.errors.full_messages.join(', ')}"
  end
end

puts "Fertig: #{updated} aktualisiert, #{not_found} nicht gefunden (keine Namen → übersprungen), #{skipped} Fehler."
