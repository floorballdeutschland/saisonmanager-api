class LicenseFeeCalculation < ApplicationRecord
  require 'csv'
  require 'json'

  attr_accessor :hash, :prefix

  def self.load_saved(id)
    c = LicenseFeeCalculation.find id

    if c
      file = File.read(c.path + c.filename_json)
      c.hash = JSON.parse(file)
      c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_license_fee_calculation"
      c
    end
  end

  def self.start_calculation(user_id,season = Setting.current_season, deadline = Date.today)
    c = LicenseFeeCalculation.new
    c.started_at = Time.now
    c.season_id = season
    c.user_id = user_id
    c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_license_fee_calculation"
    c.save

    players = Player.all
    count = players.count

    c.hash = players.each_with_index.map do |p,i|
      percent = 100.0 * (i+1)/count
      c.update_attributes(current_dataset: p.id, percent: percent )
      p.license_hash(season)
    end

    c
  end

  def save_json
    filename_json = "#{prefix}.json"

    full_path = path+filename_json
    File.open(full_path, 'w') {|f| f.write(hash.to_json) }
    update_attributes(filename_json: filename_json )
  end

  def load_json
    full_path = path + filename_json

    file = File.open(full_path, "r")
    file.read if file
  end

  def save_csv
    filename_csv = "#{prefix}.csv"

    full_path = path+filename_csv
    File.open(full_path, 'w') {|f| f.write(to_csv) }
    update_attributes(filename_csv: filename_csv )
  end

  def load_csv
    full_path = path + filename_csv

    file = File.open(full_path, "r")
    file.read if file
  end

  def to_csv
    CSV.generate(headers: true) do |csv|
      csv << table_fields

      hash.each do |player|
        csv << table_fields.map{ |attr| player[attr] }
      end
    end
  end

  def save_xlsx
    filename_xlsx = "#{prefix}.xlsx"
    full_path = path + filename_xlsx

    Xlsxtream::Workbook.open(full_path) do |xlsx|
      xlsx.write_worksheet prefix do |sheet|
        sheet << table_fields

        hash.each do |player|
          sheet << table_fields.map{ |attr| player[attr] }
        end
      end
    end


    update_attributes(filename_xls: filename_xlsx )
  end

  def load_xlsx
    full_path = path+filename_xls

    file = File.open(full_path, "r")
    file.read if file
  end

  def path
    path = "#{Rails.root}/tmp/"
  end

  def table_fields
    %w{id first_name last_name birthdate male home_club_id home_club home_club_operation home_club_state clubs club_ids team_id league_class_id league_class league_category_id league_category license_clubs license_club license_club_state}
  end
end

=begin
 gem install json2csv

=end

