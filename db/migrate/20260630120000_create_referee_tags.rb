class CreateRefereeTags < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_tags do |t|
      t.string :name, null: false
      t.string :color
      # nullable: Tags ohne Spielbetrieb sind global (für Admin/FD sichtbar),
      # ein LV-Ansetzer bekommt beim Anlegen seinen eigenen Spielbetrieb gesetzt.
      t.references :game_operation, foreign_key: true, index: false

      t.timestamps
    end

    add_index :referee_tags, %i[game_operation_id name], unique: true
  end
end
