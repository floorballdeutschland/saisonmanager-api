class LicenseFeeCalculation < ApplicationRecord
  require 'csv'
  require 'json'

  # Kennzeichnet eine Lizenz, die die Abrechnung einer zusammengefuehrten
  # Dublette ihrem Master zurechnet (siehe merged_duplicate_licenses). Wird nur
  # im Speicher gesetzt, nie gespeichert.
  MERGED_FROM_KEY = 'merged_from_id'.freeze

  attr_accessor :interal_hash, :other_hash, :prefix, :merge_warnings

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

  # Abgerechnet wird je Spielbetrieb. Massgeblich sind die Liga, unter deren
  # Team die Lizenz laeuft (`league_id`, `license_club`), und der Spielbetrieb
  # des Heimatvereins (`home_club_operation`). Das Bundesland des Vereins ist
  # dafuer ohne Belang: `home_club_state` und `license_club_state` sind reine
  # Zusatzspalten des Exports, gruppiert wird nicht danach.
  #
  # Bis 1.87.0 trug diese Methode zu Beginn das fehlende Bundesland aus der
  # Postleitzahl nach. Der Nachtrag war seit dem Rails-Upgrade kaputt
  # (`update_attributes`) und liess die Berechnung abbrechen, bevor sie
  # irgendetwas gerechnet hatte. Er ist ersatzlos entfallen und bewusst nicht
  # repariert worden: Eine Auswertung soll keine Stammdaten schreiben.
  def self.start_calculation(user_id, season = Setting.current_season_id, _deadline = Date.today)
    c = LicenseFeeCalculation.new
    c.started_at = Time.now
    c.season_id = season
    c.user_id = user_id
    c.prefix = "#{c.started_at.strftime('%Y%m%d%I%M%S')}_license_fee_calculation"
    c.save

    # Zusammengefuehrte Dubletten zaehlen nicht als eigene Spieler: Ihre Lizenzen
    # gehoeren dem Master (siehe merged_duplicate_licenses).
    players = Player.where(merged_into_id: nil)
    count = players.count
    extra_licenses, c.merge_warnings = merged_duplicate_licenses(season)
    c.merge_warnings.each { |w| Rails.logger.warn("LicenseFeeCalculation: #{w}") }

    c.interal_hash = []
    c.other_hash = []

    players.each_with_index.each do |p, i|
      percent = 100.0 * (i + 1) / count
      c.update(current_dataset: p.id, percent:)
      extra = extra_licenses.fetch(p.id, [])
      c.interal_hash << p.main_license_hash(season, extra_licenses: extra)
      c.other_hash << p.secondary_license_hash(season, extra_licenses: extra)
    end

    c.other_hash = c.other_hash.flatten.compact

    c
  end

  # Regel: Wird eine Dublette zusammengefuehrt, zaehlen alle ihre Lizenzen, als
  # gehoerten sie dem Master. Ist der Master selbst spaeter zusammengefuehrt
  # worden, ist der Endpunkt der Kette gemeint.
  #
  # `merge_into!` kopiert die Lizenzen auf den Master (`_merge_licenses`): mit
  # derselben ID, oder bei derselben Mannschaft in dessen Lizenz eingemischt. Die
  # Dublette behaelt ihre Eintraege (geloescht, abgelehnte bleiben abgelehnt).
  # Bis hierher lief die Abrechnung ueber `Player.all` und berechnete solche
  # Lizenzen deshalb zweimal voll, einmal beim Master und einmal bei der
  # Dublette (Stichtag 31.10.2026: fuenf Dubletten, 70 EUR).
  #
  # Dieselbe Lizenz ist eine mit gleicher ID oder fuer dieselbe Mannschaft (die
  # Mannschaft legt die Saison fest). Sie faellt weg. Fehlt eine Lizenz der
  # Dublette beim Master, etwa nach einer frueheren Zusammenfuehrung ohne
  # Lizenzuebernahme, wird sie ihm hier zugerechnet: Haupt- oder Zusatzlizenz
  # entscheidet sich dann zusammen mit seinen eigenen. Das ist ein Datenfehler,
  # deshalb gibt es dazu eine Warnung.
  #
  # Rueckgabe: [{ master_id => [Lizenz, ...] }, [Warnung, ...]]
  def self.merged_duplicate_licenses(season)
    duplicates = Player.where.not(merged_into_id: nil).to_a
    return [{}, []] if duplicates.empty?

    target_of = duplicates.to_h { |d| [d.id, d.merged_into_id] }
    end_of_chain = lambda do |id|
      seen = Set.new
      id = target_of[id] while target_of.key?(id) && seen.add?(id)
      id
    end
    masters = Player.where(id: duplicates.map { |d| end_of_chain.call(d.id) }.uniq).index_by(&:id)

    extras = Hash.new { |h, k| h[k] = [] }
    warnings = []
    duplicates.each do |dup|
      master = masters[end_of_chain.call(dup.id)]
      dup_licenses = Array(dup.billable_licenses(season))
      next if dup_licenses.empty?

      unless master && master.merged_into_id.nil?
        warnings << "Dublette ##{dup.id}: Master ##{dup.merged_into_id} nicht auffindbar, " \
                    "#{dup_licenses.size} Lizenz(en) nicht berechnet"
        next
      end

      known = Array(master.current_licenses(season)) + extras[master.id]
      dup_licenses.each do |lic|
        next if known.any? { |k| same_license?(k, lic) }

        copy = lic.deep_dup.merge(MERGED_FROM_KEY => dup.id)
        extras[master.id] << copy
        known << copy
        warnings << "Lizenz #{lic['id']} (Team #{lic['team_id']}) der Dublette ##{dup.id} fehlt beim " \
                    "Master ##{master.id} und wird ihm zugerechnet"
      end
    end

    [extras.to_h, warnings]
  end

  def self.same_license?(known, candidate)
    (known['id'].present? && known['id'] == candidate['id']) ||
      known['team_id'].to_i == candidate['team_id'].to_i
  end
  private_class_method :same_license?

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
    %w[id first_name last_name birthdate gender home_club_id home_club home_club_operation home_club_state clubs club_ids
       license_id team_id league_id league_class_id league_class league_category_id league_category license_clubs license_club license_club_state history
       merged_from_id]
  end
end

#  gem install json2csv
#  c = LicenseFeeCalculation.start_calculation 689
#  c.save_files
