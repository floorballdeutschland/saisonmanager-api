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
            c.errors["#{l.game_operation_id} - #{game.id}"] = 'Schiri Anzahl falsch'
          else
            game.referee_ids.each do |ref_id|
              c.referees[ref_id] ||= []
              c.referees[ref_id] << { game_id: game.id, league_id: league_id, game_operation_id: l.game_operation_id, league_class_id: l.league_class_id, league_category_id: l.league_category_id, league_female: l.female, league_name: l.name}
            end
          end
        end
      end
    end

    # Do the calculation
    c.referees.each do |license_number, entries|
      num = license_number.to_s.rjust(4, ' ')
      c.referees_count[num] = {}
      entries.each do |entry|
        key = "#{entry[:game_operation_id]}-#{entry[:league_name]}"
        c.league_names << key
        c.referees_count[num][key] ||= 0
        c.referees_count[num][key] += 1
      end
    end

    c.league_names.uniq!.sort!

    docs = ({ref: c.referees, errors: c.errors, leagues: c.league_docs, counted_games: c.referees_count})
    File.open("#{c.prefix}.json", 'w') do |file|
      file.write JSON.pretty_generate(docs)
    end

    File.open("#{c.prefix}_errors.json", 'w') do |file|
      file.write JSON.pretty_generate(c.errors)
    end

    data = 'id,'
    c.league_names.each { |ln| data += '"' + ln + '", ' }
    data += "\n"

    c.referees_count.sort.each do |license_number, entries|
      ref = "#{license_number.strip}, "
      c.league_names.each do |ln|
        ref += "#{entries[ln]}, "
      end
      ref += "\n"
      data += ref
    end

    File.open("#{c.prefix}.csv", 'w') do |file|
      file.write data
    end


    c
  end
end

=begin
 gem install json2csv
rc=RefereeCalculation.start_calculation(689, 9)

=end

