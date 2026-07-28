class CreateRefereeClubExclusions < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_club_exclusions do |t|
      t.references :referee, null: false, foreign_key: true
      t.references :club, null: false, foreign_key: true
      # Kurze Begründung aus dem Antrag (oder vom Ansetzer bei direkter Pflege).
      t.string :reason, limit: 120
      t.integer :created_by
      # Herkunfts-Antrag, falls der Eintrag aus einem genehmigten Antrag stammt.
      t.bigint :request_id

      t.timestamps
    end

    add_index :referee_club_exclusions, %i[referee_id club_id], unique: true
  end
end
