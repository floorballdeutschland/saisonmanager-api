require 'open-uri'
require 'net/http'

namespace :clubs do
  desc "Import club logos from saisonmanager.de via game API"
  task import_logos: :environment do
    SOURCE_HOST = 'https://saisonmanager.de'.freeze

    total   = Club.count
    skipped = 0
    imported = 0
    no_game  = 0
    no_logo  = 0
    errors   = 0

    puts "Importing logos for #{total} clubs..."

    Club.find_each do |club|
      # Find one team that belongs to this club and has a game
      team = Team.where(club_id: club.id).joins(
        "INNER JOIN games ON games.home_team_id = teams.id OR games.guest_team_id = teams.id"
      ).first

      if team.nil?
        no_game += 1
        next
      end

      # Find the game
      game = Game.where(home_team_id: team.id)
                 .or(Game.where(guest_team_id: team.id))
                 .first

      if game.nil?
        no_game += 1
        next
      end

      # Fetch game details from saisonmanager.de
      begin
        uri = URI("#{SOURCE_HOST}/api/v2/games/#{game.id}.json")
        response = Net::HTTP.get_response(uri)

        unless response.is_a?(Net::HTTPSuccess)
          errors += 1
          next
        end

        game_data = JSON.parse(response.body)

        logo_path = if game_data['home_team_id'] == team.id
                      game_data['home_team_logo']
                    else
                      game_data['guest_team_logo']
                    end

        if logo_path.blank?
          no_logo += 1
          next
        end

        logo_url = SOURCE_HOST + logo_path
        filename = File.basename(logo_path.split('?').first)
        content_type = case filename.downcase
                       when /\.png$/ then 'image/png'
                       when /\.jpe?g$/ then 'image/jpeg'
                       when /\.svg$/ then 'image/svg+xml'
                       else 'image/png'
                       end

        # Download and attach — URI.open follows redirects
        image_data = URI.open(logo_url, read_timeout: 15, open_timeout: 10)

        club.logo.attach(
          io: image_data,
          filename: filename,
          content_type: content_type
        )

        imported += 1
        print "." if imported % 20 == 0

      rescue JSON::ParserError, Net::HTTPError, OpenURI::HTTPError, SocketError, Timeout::Error => e
        errors += 1
        puts "\n  ERROR club #{club.id} (#{club.name}): #{e.class} #{e.message[0..60]}"
      rescue => e
        errors += 1
        puts "\n  ERROR club #{club.id} (#{club.name}): #{e.class} #{e.message[0..60]}"
      end

      sleep 0.05  # gentle rate limiting
    end

    puts "\n\nDone."
    puts "  Imported:      #{imported}"
    puts "  No game found: #{no_game}"
    puts "  No logo on .de: #{no_logo}"
    puts "  Errors:        #{errors}"
  end
end
