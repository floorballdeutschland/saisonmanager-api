class CreateRefereeFeedbacks < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_feedbacks do |t|
      t.references :game, null: false, foreign_key: true
      t.bigint :team_id, null: false
      t.bigint :club_id
      t.bigint :submitted_by_user_id
      # Gespann des Spiels zum Zeitpunkt der Abgabe (Referee-PKs). Nullable, da
      # ein angesetzter Schiri später zusammengeführt/gelöscht werden kann.
      t.bigint :referee_1_id
      t.bigint :referee_2_id
      # Klartext-Snapshot der Schiri-Namen für die robuste Anzeige.
      t.string :referee_names
      t.integer :line_rating, null: false
      t.text :line_comment
      t.integer :communication_rating, null: false
      t.text :communication_comment
      t.text :general_comment
      # 'visible' (Standard) oder 'hidden' (von RSK/Ansetzer ausgeblendet, da unsachlich).
      t.string :status, null: false, default: 'visible'

      t.timestamps
    end

    # Ein Feedback je Spiel und Team – sobald ein TM/VM des Vereins abgegeben hat,
    # ist der Slot belegt.
    add_index :referee_feedbacks, %i[game_id team_id], unique: true
    add_index :referee_feedbacks, :team_id
    add_index :referee_feedbacks, :referee_1_id
    add_index :referee_feedbacks, :referee_2_id

    add_column :leagues, :referee_feedback_enabled, :boolean, default: false, null: false
  end
end
