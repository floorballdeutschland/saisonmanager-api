class LicenseFeeCalculation < ApplicationRecord
  require 'csv'
  require 'json'

  attr_accessor :interal_hash, :other_hash, :prefix

  def self.load_saved(id)
    c = LicenseFeeCalculation.find id

    if c
      file = File.read(c.path + c.filename_json)
      c.interal_hash = JSON.parse(file)
      file_other = File.read(c.path + c.filename_other_json)
      c.other_hash = JSON.parse(file_other)
      c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_license_fee_calculation"
      c
    end
  end

  def self.start_calculation(user_id, season = Setting.current_season_id, _deadline = Date.today)
    # update clubs where state is not set right now (by postcode)
    Club.where(state: nil).each(&:update_state)

    c = LicenseFeeCalculation.new
    c.started_at = Time.now
    c.season_id = season
    c.user_id = user_id
    c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_license_fee_calculation"
    c.save

    players = Player.all
    count = players.count

    c.interal_hash = []
    c.other_hash = []

    players.each_with_index.each do |p, i|
      percent = 100.0 * (i + 1) / count
      c.update(current_dataset: p.id, percent:)
      c.interal_hash << p.main_license_hash(season)
      c.other_hash << p.secondary_license_hash(season)
    end

    c.other_hash = c.other_hash.flatten.compact

    c
  end

  def save_files
    save_json
    save_csv
    save_xlsx
  end

  def save_json
    filename_json = "#{prefix}.json"
    filename_other_json = "#{prefix}_other.json"

    full_path = path + filename_json
    File.open(full_path, 'w') { |f| f.write(interal_hash.to_json) }
    update(filename_json:)

    full_path = path + filename_other_json
    File.open(full_path, 'w') { |f| f.write(other_hash.to_json) }
    update(filename_other_json:)
  end

  def load_json
    full_path = path + filename_json

    file = File.open(full_path, 'r')
    file.read if file
  end

  def save_csv
    filename_csv = "#{prefix}.csv"

    full_path = path + filename_csv
    File.open(full_path, 'w') { |f| f.write(to_csv) }
    update(filename_csv:)
  end

  def load_csv
    full_path = path + filename_csv

    file = File.open(full_path, 'r')
    file.read if file
  end

  def to_csv
    CSV.generate(headers: true) do |csv|
      csv << table_fields

      interal_hash.each do |player|
        csv << table_fields.map { |attr| player[attr] }
      end
    end
  end

  def save_xlsx
    filename_xlsx = "#{prefix}.xlsx"
    full_path = path + filename_xlsx

    Xlsxtream::Workbook.open(full_path) do |xlsx|
      xlsx.write_worksheet 'Lizenzen' do |sheet|
        sheet << table_fields

        interal_hash.each do |player|
          sheet << table_fields.map { |attr| player[attr] }
        end
      end
    end
    update(filename_xls: filename_xlsx)

    filename_xlsx = "#{prefix}_other.xlsx"
    full_path = path + filename_xlsx

    Xlsxtream::Workbook.open(full_path) do |xlsx|
      xlsx.write_worksheet 'Lizenzen' do |sheet|
        sheet << table_fields

        other_hash.each do |player|
          sheet << table_fields.map do |attr|
            puts player.to_json unless player
            player[attr]
          end
        end
      end
    end
  end

  def load_xlsx
    full_path = path + filename_xls

    file = File.open(full_path, 'r')
    file.read if file
  end

  def path
    path = "#{Rails.root}/tmp/"
  end

  def table_fields
    %w[id first_name last_name birthdate male home_club_id home_club home_club_operation home_club_state clubs club_ids
       license_id team_id league_id league_class_id league_class league_category_id league_category license_clubs license_club license_club_state history]
  end
end

#  gem install json2csv
#  c = LicenseFeeCalculation.start_calculation 689
#  c.save_files
