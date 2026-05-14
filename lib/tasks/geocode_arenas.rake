require 'net/http'
require 'json'
require 'uri'

# Geocodes arenas without address data via OSM Nominatim (free, no API key).
#
# Strategy per arena:
#   1. Extract city hint from arena name ("Leipzig (SSC)" → "Leipzig")
#   2. Try structured Nominatim query: amenity=sports_centre in that city
#   3. Try free-form: "arena name, city, Deutschland"
#   4. Try free-form: "arena name, Deutschland"
#
# Rate-limit: 1 req/s (Nominatim policy). 502 arenas ≈ 10–20 min.
#
# Usage:
#   rails arenas:geocode               # only arenas without street
#   rails arenas:geocode[force]        # re-geocode all
#   rails arenas:geocode[dry_run]      # print without saving
namespace :arenas do
  desc "Geocode arenas via OpenStreetMap Nominatim"
  task :geocode, [:mode] => :environment do |_, args|
    mode    = args[:mode].to_s
    force   = mode == 'force'
    dry_run = mode == 'dry_run'

    scope = force ? Arena.all : Arena.where(street: [nil, ''])
    total = scope.count
    puts "#{dry_run ? '[DRY RUN] ' : ''}Geocoding #{total} arenas..."

    found = 0; no_result = 0; errors = 0

    scope.find_each do |arena|
      city_hint = ArenaGeocoder.city_from_name(arena.name)
      result    = ArenaGeocoder.search(arena.name, city_hint)

      if result.nil?
        puts "  SKIP  [#{arena.id}] #{arena.name}#{city_hint ? " (hint: #{city_hint})" : ''}"
        no_result += 1
        sleep 1
        next
      end

      addr        = result['address'] || {}
      street      = addr['road'] || addr['pedestrian'] || addr['footway'] || ''
      housenumber = addr['house_number'] || ''
      postcode    = addr['postcode'] || ''
      city        = addr['city'] || addr['town'] || addr['village'] || addr['municipality'] || city_hint || ''

      puts "  OK    [#{arena.id}] #{arena.name}"
      puts "        → #{result['display_name']}"

      unless dry_run
        arena.update_columns(
          street:      street,
          housenumber: housenumber,
          postcode:    postcode,
          city:        city
        )
      end
      found += 1
      sleep 1
    rescue StandardError => e
      puts "  ERROR [#{arena.id}] #{arena.name}: #{e.message[0..80]}"
      errors += 1
      sleep 1
    end

    puts "\nDone. Geocoded: #{found}, No result: #{no_result}, Errors: #{errors}"
    exit(1) if errors.positive?
  end
end

module ArenaGeocoder
  KNOWN_CITIES = %w[
    Augsburg Aschersleben Bad\ Hersfeld Bad\ Langensalza Bad\ Wildungen Bautzen Berlin Bielefeld Bonn
    Bochum Bremen Brunsbüttel Chemnitz Cottbus Dessau Döbeln Dresden Duisburg Düsseldorf Erfurt
    Erlensee Espenau Frankfurt Freital Genthin Grimma Halle Hamburg Hannover Heidenau Heidelberg
    Hoyerswerda Ingolstadt Jena Kaufering Kiel Köln Leipzig Lintorf Lübeck Magdeburg Mainz Marburg
    München Münster Nürnberg Oldenburg Osnabrück Quedlinburg Regensburg Rosenheim Schkeuditz
    Schleswig Schwerin Sömmerda Stuttgart Ulm Weißenfels Weimar Wernigerode Wolfsburg Zwickau
  ].freeze

  # "Leipzig (SSC)" → "Leipzig", "Hamburg, Sporthalle X" → "Hamburg"
  def self.city_from_name(name)
    KNOWN_CITIES.each do |city|
      return city if name.match?(/\A#{Regexp.escape(city)}[\s,(]/i)
    end
    if (m = name.match(/,\s*([A-ZÄÖÜ][a-zäöüß\-]+(?:\s[A-ZÄÖÜ][a-zäöüß\-]+)?)\z/))
      candidate = m[1].strip
      return candidate if KNOWN_CITIES.any? { |c| c.casecmp?(candidate) }
    end
    nil
  end

  def self.search(name, city = nil)
    # Strip parenthetical suffixes for cleaner queries: "Leipzig (SSC)" → "Leipzig SSC"
    clean_name = name.gsub(/\s*\(([^)]+)\)/, ' \1').strip

    queries = []
    if city
      queries << { q: "#{clean_name}, #{city}, Deutschland" }
      queries << { amenity: clean_name, city: city, country: 'Deutschland' }
    end
    queries << { q: "#{clean_name}, Deutschland" }

    queries.each do |params|
      result = nominatim_get(params)
      return result if result
      sleep 1
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
