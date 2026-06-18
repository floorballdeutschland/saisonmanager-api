class AddKurzfristigMobilToReferees < ActiveRecord::Migration[7.1]
  def change
    add_column :referees, :kurzfristig_mobil, :boolean, default: false, null: false
  end
end
