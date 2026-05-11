class AddMatchRecordClosedAtToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :match_record_closed_at, :datetime

    # Backfill: already-closed games use record_updated_at as an approximation,
    # falling back to updated_at if record_updated_at is NULL.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE games
          SET match_record_closed_at = COALESCE(record_updated_at, updated_at)
          WHERE game_status IN ('match_record_closed', 'finalized')
        SQL
      end
    end
  end
end
