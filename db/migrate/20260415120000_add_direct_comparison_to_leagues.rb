class AddDirectComparisonToLeagues < ActiveRecord::Migration[7.0]
  def change
    add_column :leagues, :direct_comparison, :boolean, default: false, null: false
  end
end
