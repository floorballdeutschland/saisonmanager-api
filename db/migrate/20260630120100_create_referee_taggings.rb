class CreateRefereeTaggings < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_taggings do |t|
      t.references :referee, null: false, foreign_key: true, index: false
      t.references :referee_tag, null: false, foreign_key: true

      t.timestamps
    end

    add_index :referee_taggings, %i[referee_id referee_tag_id], unique: true
  end
end
