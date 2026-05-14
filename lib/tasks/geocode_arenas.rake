require 'net/http'
require 'json'
require 'uri'

# Geocodes arenas without address data via OSM Nominatim (free, no API key).
#
# Strategy per arena:
#   1. Extract city hint from arena name ("Leipzig (SSC)" → "Leipzig")
#   2. Skip if no city hint and name is too generic (e.g. "Sporthalle", "Mehrzweckhalle")
#   3. Try structured Nominatim query: amenity + city
#   4. Try free-form: "arena name, city, Deutschland"
#   5. Try free-form: "arena name, Deutschland" (only with city hint)
#
# Rate-limit: exactly 1 req/s per Nominatim policy, enforced via ensure.
#
# Usage:
#   rails arenas:geocode                     # only arenas without street
#   rails arenas:geocode[force]              # re-geocode all
#   rails arenas:geocode[dry_run]            # print without saving
#   rails arenas:geocode[force,dry_run]      # re-geocode all, print only
namespace :arenas do
  desc "Geocode arenas via OpenStreetMap Nominatim"
  task :geocode, %i[mode mode2] => :environment do |_, args|
    modes   = [args[:mode].to_s, args[:mode2].to_s]
    force   = modes.include?('force')
    dry_run = modes.include?('dry_run')

    scope = force ? Arena.all : Arena.where(street: [nil, ''])
    total = scope.count
    puts "#{dry_run ? '[DRY RUN] ' : ''}Geocoding #{total} arenas (force=#{force})..."

    found = 0
    skipped = 0
    no_result = 0
    errors = 0

    scope.find_each do |arena|
      city_hint = ArenaGeocoder.city_from_name(arena.name)

      if city_hint.nil? && ArenaGeocoder.generic_name?(arena.name)
        puts "  SKIP  [#{arena.id}] #{arena.name} — generic name, no city context"
        skipped += 1
        next
      end

      result = nil
      begin
        result = ArenaGeocoder.search(arena.name, city_hint)
      rescue StandardError => e
        puts "  ERROR [#{arena.id}] #{arena.name}: #{e.message[0..80]}"
        errors += 1
        next
      ensure
        sleep 1
      end

      if result.nil?
        puts "  SKIP  [#{arena.id}] #{arena.name}#{city_hint ? " (hint: #{city_hint})" : ''} — no result"
        no_result += 1
        next
      end

      addr        = result['address'] || {}
      street      = addr['road'] || addr['pedestrian'] || addr['footway'] || ''
      housenumber = addr['house_number'] || ''
      postcode    = addr['postcode'] || ''
      city        = addr['city'] || addr['town'] || addr['village'] ||
                    addr['municipality'] || addr['hamlet'] || addr['suburb'] ||
                    city_hint || ''

      puts "  #{dry_run ? '[DRY] ' : ''}OK    [#{arena.id}] #{arena.name}"
      puts "        → #{result['display_name']}"

      unless dry_run
        updates = {}
        updates[:street]      = street      if street.present?
        updates[:housenumber] = housenumber if housenumber.present?
        updates[:postcode]    = postcode    if postcode.present?
        updates[:city]        = city        if city.present?
        arena.update_columns(updates) if updates.any?
      end
      found += 1
    end

    puts "\nDone. Geocoded: #{found}, Skipped (generic): #{skipped}, No result: #{no_result}, Errors: #{errors}"
    abort "Geocoding finished with #{errors} errors." if errors.positive?
  end
end

module ArenaGeocoder
  KNOWN_CITIES = [
    'Augsburg', 'Aschersleben', 'Bad Hersfeld', 'Bad Langensalza', 'Bad Wildungen',
    'Bautzen', 'Berlin', 'Bielefeld', 'Bochum', 'Bonn', 'Bremen', 'Brunsbüttel',
    'Chemnitz', 'Cottbus', 'Dessau', 'Döbeln', 'Dresden', 'Duisburg', 'Düsseldorf',
    'Erfurt', 'Erlensee', 'Espenau', 'Frankfurt', 'Freital', 'Genthin', 'Grimma',
    'Halle', 'Hamburg', 'Hannover', 'Heidenau', 'Heidelberg', 'Hochdahl',
    'Hoyerswerda', 'Ingolstadt', 'Jena', 'Kaufering', 'Kiel', 'Köln', 'Landsberg',
    'Leipzig', 'Lintorf', 'Lübeck', 'Magdeburg', 'Mainz', 'Mainburg', 'Marburg',
    'München', 'Münster', 'Nebra', 'Nürnberg', 'Oldenburg', 'Osnabrück',
    'Quedlinburg', 'Regensburg', 'Rosenheim', 'Schkeuditz', 'Schleswig', 'Schriesheim',
    'Schwerin', 'Sömmerda', 'Stuttgart', 'Ulm', 'Weißenfels', 'Weimar',
    'Wernigerode', 'Wolfsburg', 'Zwickau'
  ].freeze

  GENERIC_PREFIXES = %w[
    Sporthalle Sportzentrum Sportpark Mehrzweckhalle Turnhalle Schulsporthalle
    Dreifachturnhalle Dreifeldsporthalle Doppelsporthalle Halle
  ].freeze

  # "Leipzig (SSC)" → "Leipzig", "Hamburg, Sporthalle X" → "Hamburg"
  def self.city_from_name(name)
    KNOWN_CITIES.each do |city|
      return city if name.match?(/\A#{Regexp.escape(city)}[\s,(]/i)
    end
    if (m = name.match(/,\s*([A-ZÄÖÜ][a-zäöüß\-]+(?:\s[A-ZÄÖÜ][a-zäöüß\-]+)?)\z/))
      canonical = KNOWN_CITIES.find { |c| c.casecmp?(m[1].strip) }
      return canonical if canonical
    end
    nil
  end

  # Returns true for names that are too generic to geocode without a city hint.
  def self.generic_name?(name)
    clean = name.gsub(/\s*\(.*?\)/, '').strip
    GENERIC_PREFIXES.any? { |prefix| clean.match?(/\A#{Regexp.escape(prefix)}(\s|\z)/i) }
  end

  def self.search(name, city = nil)
    clean_name = name.gsub(/\s*\(([^)]+)\)/, ' \1').strip

    queries = []
    if city
      queries << { amenity: clean_name, city: city, country: 'Deutschland' }
      queries << { q: "#{clean_name}, #{city}, Deutschland" }
    end
    # Only try without city hint if name is specific enough
    queries << { q: "#{clean_name}, Deutschland" } if city

    first = true
    queries.each do |params|
      sleep 1 unless first
      first = false
      result = nominatim_get(params)
      return result if result
    end
    nil
  end

  def self.nominatim_get(params)
    uri = URI('https://nominatim.openstreetmap.org/search')
    uri.query = URI.encode_www_form(params.merge(format: 'json', addressdetails: 1, limit: 1, countrycodes: 'de'))
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = 'saisonmanager/1.0 (d.kehne@floorball.de)'
    req['Accept']     = 'application/json'
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: 10, read_timeout: 10) { |h| h.request(req) }
    return nil unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    data.first
  end
end
