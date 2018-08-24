class RefereeCalculation < ApplicationRecord
  require 'csv'
  require 'json'

  attr_accessor :hash, :other_hash, :prefix

  attr_accessor :league_ids, :league_docs, :game_day_ids, :game_docs, :referees, :referees_count, :errors, :league_names

  # def self.load_saved(id)
  #   c = RefereeCalculation.find id

  #   if c
  #     file = File.read(c.path + c.filename_json)
  #     c.hash = JSON.parse(file)
  #     file_other = File.read(c.path + c.filename_other_json)
  #     c.other_hash = JSON.parse(file_other)
  #     c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_referee_calculation"
  #     c
  #   end
  # end

  def self.start_calculation(user_id,season = Setting.current_season)
    c = RefereeCalculation.new
    c.started_at = Time.now
    c.season_id = season
    c.referees = {}
    c.referees_count = {}
    c.errors = {}
    c.league_names = []
    c.user_id = user_id
    c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_referee_calculation"
    c.save

    leagues = League.where season_id: season
    league_ids = leagues.map(&:id)

    league_ids.each do |league_id|
      puts "league: #{league_id}"
      game_days = GameDay.where league_id: league_id
      game_day_ids = game_days.map(&:id)

      l = League.find league_id

      game_day_ids.each do |game_day_id|
        puts "game_day: #{game_day_id}"
        games = Game.where game_day: game_day_id

        games.each do |game|
          if game.record_created_at.blank?
            puts "Fehler bei Spiel: #{game.id}, Liga: #{league_id}: Spiel noch nicht gespielt"
          elsif game.referee_ids.nil? || game.referee_ids.count != 2
            puts "Fehler bei Spiel: #{game.id}, Liga: #{league_id}"
            errors["#{l.game_operation_id} - #{game.id}"] = 'Schiri Anzahl falsch'
          else
            game.referee_ids.each do |ref_id|
              referees[ref_id] ||= []
              referees[ref_id] << { game_id: game.id, league_id: league_id, game_operation_id: l.game_operation_id, league_class_id: l.league_class_id, league_category_id: l.league_category_id, league_female: l.female, league_name: l.name}
            end
          end
        end
      end
    end


    c
  end
end

=begin
 gem install json2csv

=end

