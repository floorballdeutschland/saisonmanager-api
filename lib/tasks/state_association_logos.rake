require 'open-uri'
require 'net/http'

namespace :state_associations do
  # Mapping: StateAssociation#name → logo URL
  # Extend this list as more logos become available.
  LOGO_URL_MAPPING = {
    'Baden-Württemberg' => 'https://b3257445.smushcdn.com/3257445/wp-content/uploads/2022/05/FloorballBW2022-1024x296.png',
    'Bayern'            => 'https://b3257445.smushcdn.com/3257445/wp-content/uploads/2022/03/floorballbayern_weissBlau-1024x349.png'
  }.freeze

  desc "Download and attach logos to StateAssociation records"
  task import_logos: :environment do
    imported = 0
    skipped  = 0
    errors   = 0

    LOGO_URL_MAPPING.each do |name, url|
      sa = StateAssociation.find_by(name: name)
      unless sa
        puts "  SKIP – no StateAssociation found for '#{name}'"
        skipped += 1
        next
      end

      if sa.logo.attached?
        puts "  SKIP – #{name} already has a logo"
        skipped += 1
        next
      end

      begin
        filename = File.basename(URI.parse(url).path)
        content_type = filename.end_with?('.png') ? 'image/png' : 'image/jpeg'
        image_data = URI.open(url, 'User-Agent' => 'saisonmanager/1.0', read_timeout: 20, open_timeout: 10)
        sa.logo.attach(io: image_data, filename: filename, content_type: content_type)
        puts "  OK – #{name}"
        imported += 1
      rescue OpenURI::HTTPError, SocketError, Timeout::Error => e
        puts "  ERROR – #{name}: #{e.message[0..80]}"
        errors += 1
      end
    end

    puts "\nDone. Imported: #{imported}, Skipped: #{skipped}, Errors: #{errors}"
    puts "\nNote: Most Landesverband logos are not yet available on floorball.de." if imported < LOGO_URL_MAPPING.size
    puts "Add entries to LOGO_URL_MAPPING in lib/tasks/state_association_logos.rake as they become available."
  end

  desc "Remove all logos from StateAssociation records (use before re-importing)"
  task purge_logos: :environment do
    count = 0
    StateAssociation.find_each do |sa|
      next unless sa.logo.attached?

      sa.logo.purge
      puts "  Purged logo for #{sa.name}"
      count += 1
    end
    puts "Done. Purged #{count} logos."
  end
end
