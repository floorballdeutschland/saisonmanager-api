# lib/tasks/archive_season.rake

namespace :season do
  desc 'Archive floorball season data'
  task archive: :environment do
    require 'fileutils'
    require 'net/http'
    require 'uri'
    require 'json'

    # Set the season to be archived
    season_id = 16

    # Set the path to the folder where the JSONs are stored
    path_prefix = Rails.root.join('tmp', 'season_archives', season_id.to_s)

    # Function to download a JSON file
    def download_json(url, base_path)
      puts "Downloading: #{url}"
      uri = URI(url)
      response = Net::HTTP.get(uri)
      relative_path = URI(url).path

      # remove the leading slash, if present
      relative_path = relative_path[1..-1] if relative_path.start_with?('/')
      destination = base_path.join(relative_path)

      # Create the necessary directory structure
      FileUtils.mkdir_p(destination.dirname)
      json_data = response.force_encoding('UTF-8')
      File.write(destination, json_data)
    rescue StandardError => e
      puts "Failed to download #{url}: #{e.message}"
      {}
    end

    # Define the base URL for the API
    base_url = 'https://saisonmanager.de/api/v2'

    # Initial download of the game operations and leagues
    puts "Archiving season #{season_id} started."
    init_url = "#{base_url}/init.json"
    download_json(init_url, path_prefix)

    game_operations = GameOperation.all
    leagues = []

    puts 'Archiving GameOperation'
    game_operations.each do |go|
      go_url = "#{base_url}/game_operations/#{go.id}/leagues/#{season_id}.json"
      download_json(go_url, path_prefix)
    end

    game_ids = []

    puts 'Archiving Leagues'
    leagues = League.includes(:game_days).where(season_id:).reorder(:id)
    # Download data for each league
    leagues.each do |league|
      league_id = league['id']
      league_urls = [
        "#{base_url}/leagues/#{league_id}.json",
        "#{base_url}/leagues/#{league_id}/schedule.json",
        "#{base_url}/leagues/#{league_id}/table.json",
        "#{base_url}/leagues/#{league_id}/scorer.json",
        "#{base_url}/leagues/#{league_id}/game_days/current/schedule.json"
      ]

      league_urls << "#{base_url}/leagues/#{league_id}/grouped_table.json" if league.league_type == 'champ'

      league_urls.each do |url|
        download_json(url, path_prefix)
      end

      # Download data for each game day in this league
      game_days = league.game_days || []
      game_day_numbers = game_days.pluck(:number).uniq.sort
      game_days.each do |game_day|
        game_ids << game_day.games.pluck(:id)
      end

      game_day_numbers.each do |game_day_number|
        game_day_url = "#{base_url}/leagues/#{league_id}/game_days/#{game_day_number}/schedule.json"
        download_json(game_day_url, path_prefix)
      end
    end

    puts 'Archiving Games'
    game_ids.flatten!
    game_ids.sort.uniq.each do |game_id|
      game_url = "#{base_url}/games/#{game_id}.json"
      download_json(game_url, path_prefix)
    end

    puts "Archiving season #{season_id} completed."
  end
end
