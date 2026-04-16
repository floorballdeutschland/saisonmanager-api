class FixClubsGameOperationsHashDefault < ActiveRecord::Migration[7.0]
  def up
    execute <<~SQL
      UPDATE clubs
      SET game_operations_hash = '[]'::jsonb
      WHERE jsonb_typeof(game_operations_hash) = 'object'
    SQL
  end

  def down
    # Not reversible – we cannot know which clubs originally had {}
  end
end
