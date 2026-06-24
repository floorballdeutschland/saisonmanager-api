# Gültigkeitsdauer (Jahre) je Schiri-Lizenzstufe. Default 2; bestehende
# gueltigkeit-Werte bleiben unangetastet (nur Neuvergaben nutzen die Dauer).
class AddValidityYearsToRefereeLicenseLevels < ActiveRecord::Migration[7.1]
  def change
    add_column :referee_license_levels, :validity_years, :integer, default: 2, null: false
  end
end
