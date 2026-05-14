class MigratePlayerGenderAndDropMale < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      UPDATE players
      SET gender = CASE WHEN male = true THEN 'M' ELSE 'W' END
      WHERE gender IS NULL AND male IS NOT NULL
    SQL

    remove_column :players, :male
  end

  def down
    add_column :players, :male, :boolean

    execute <<~SQL
      UPDATE players
      SET male = (gender = 'M')
      WHERE gender IS NOT NULL
    SQL
  end
end
