class CreateStateAssociations < ActiveRecord::Migration[7.0]
  def change
    create_table :state_associations do |t|
      t.string :name, null: false
      t.string :short_name

      t.timestamps
    end
  end
end
