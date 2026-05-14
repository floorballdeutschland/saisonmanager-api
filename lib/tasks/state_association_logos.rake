require 'open-uri'

# Mapping: StateAssociation#name → logo URL
# Extend this list as more logos become available.
STATE_ASSOCIATION_LOGO_URLS = {
  'Baden-Württemberg' => 'https://b3257445.smushcdn.com/3257445/wp-content/uploads/2022/05/FloorballBW2022-1024x296.png',
  'Bayern'            => 'https://b3257445.smushcdn.com/3257445/wp-content/uploads/2022/03/floorballbayern_weissBlau-1024x349.png'
}.freeze

namespace :state_associations do
  desc "Download and attach logos to StateAssociation records"
  task import_logos: :environment do
    imported = 0
    skipped  = 0
    errors   = 0

    STATE_ASSOCIATION_LOGO_URLS.each do |name, url|
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
        uri = URI.parse(url)
        raise ArgumentError, "Unsafe URL scheme: #{uri.scheme}" unless %w[http https].include?(uri.scheme)

        image_data = uri.open('User-Agent' => 'saisonmanager/1.0', read_timeout: 20, open_timeout: 10)
        content_type = image_data.content_type.presence || 'image/png'
        filename = File.basename(uri.path).presence || "logo-#{sa.id}.png"

        sa.logo.attach(io: image_data, filename: filename, content_type: content_type)
        puts "  OK – #{name}"
        imported += 1
      rescue StandardError => e
        puts "  ERROR – #{name}: #{e.class} #{e.message[0..80]}"
        errors += 1
      end
    end

    puts "\nDone. Imported: #{imported}, Skipped: #{skipped}, Errors: #{errors}"
    if imported < STATE_ASSOCIATION_LOGO_URLS.size - skipped
      puts "\nNote: Most Landesverband logos are not yet available on floorball.de."
      puts "Add entries to STATE_ASSOCIATION_LOGO_URLS in lib/tasks/state_association_logos.rake as they become available."
    end
    exit(1) if errors.positive?
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
