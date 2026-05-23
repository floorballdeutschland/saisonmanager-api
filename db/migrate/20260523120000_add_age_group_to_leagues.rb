class AddAgeGroupToLeagues < ActiveRecord::Migration[7.0]
  def up
    add_column :leagues, :age_group, :string
    execute "UPDATE leagues SET age_group = CASE WHEN female = true THEN 'Damen' ELSE 'Herren' END"
  end

  def down
    remove_column :leagues, :age_group
  end
end
