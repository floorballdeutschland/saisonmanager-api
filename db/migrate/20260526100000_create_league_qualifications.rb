class CreateLeagueQualifications < ActiveRecord::Migration[7.0]
  def change
    create_table :league_qualifications do |t|
      t.references :source_league, null: false, foreign_key: { to_table: :leagues }
      t.references :target_league, null: true, foreign_key: { to_table: :leagues }
      t.integer :rank_from, null: false
      t.integer :rank_to, null: false
      t.string :qualification_type, null: false
      t.string :label

      t.timestamps
    end
  end
end
