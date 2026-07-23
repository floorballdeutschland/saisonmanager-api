class CreateFeedbackThemes < ActiveRecord::Migration[7.1]
  def change
    create_table :feedback_themes do |t|
      t.string :name, null: false
      t.string :color
      t.integer :position
      t.timestamps
    end
    add_index :feedback_themes, :name, unique: true

    create_table :feedback_theme_taggings do |t|
      t.references :referee_feedback, null: false, foreign_key: true
      t.references :feedback_theme, null: false, foreign_key: true
      t.bigint :tagged_by_user_id
      t.timestamps
    end
    add_index :feedback_theme_taggings, %i[referee_feedback_id feedback_theme_id],
              unique: true, name: 'index_feedback_theme_taggings_on_feedback_and_theme'
  end
end
