namespace :referees do
  desc 'Import referee master data from referees.json into the referees table (idempotent)'
  task import: :environment do
    file_path = Rails.root.join('referees.json')
    unless File.exist?(file_path)
      puts "referees.json not found at #{file_path}"
      exit 1
    end

    data = JSON.parse(File.read(file_path))
    created = 0
    updated = 0
    skipped = 0

    data.each do |r|
      lizenznummer = r['Lizenznummer'].to_i
      next if lizenznummer.zero?

      referee = Referee.find_or_initialize_by(lizenznummer: lizenznummer)
      is_new = referee.new_record?

      referee.assign_attributes(
        vorname: r['Vorname'].to_s.strip,
        nachname: r['Name'].to_s.strip,
        landesverband: r['Region'].to_s.strip.presence,
        lizenzstufe: r['Lizenz'].to_s.strip.presence,
        verein: r['Verband'].to_s.strip.presence
      )

      if referee.valid? && referee.save
        is_new ? created += 1 : updated += 1
      else
        puts "Skipped #{lizenznummer} (#{referee.errors.full_messages.join(', ')})"
        skipped += 1
      end
    end

    puts "Done: #{created} created, #{updated} updated, #{skipped} skipped (total: #{data.size})"
  end
end
