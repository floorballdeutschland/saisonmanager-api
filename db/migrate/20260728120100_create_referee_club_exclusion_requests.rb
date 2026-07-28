class CreateRefereeClubExclusionRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_club_exclusion_requests do |t|
      t.references :referee, null: false, foreign_key: true
      t.references :club, null: false, foreign_key: true
      t.string :kind, null: false, comment: 'add = Verein aufnehmen, remove = Verein streichen'
      t.string :reason, limit: 120, null: false
      t.string :status, null: false, default: 'pending'
      t.string :decision_note, limit: 200
      t.integer :decided_by
      t.datetime :decided_at

      t.timestamps
    end

    add_index :referee_club_exclusion_requests, :status
    # Pro Schiri und Verein darf nur ein Antrag offen sein; entschiedene Anträge
    # bleiben als Historie erhalten.
    add_index :referee_club_exclusion_requests, %i[referee_id club_id],
              unique: true,
              where: "status = 'pending'",
              name: 'index_referee_club_exclusion_requests_pending_unique'
  end
end
