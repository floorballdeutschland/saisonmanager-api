class DeduplicateArenas < ActiveRecord::Migration[7.0]
  def up
    # Group arenas by normalized (name, address) where address is not blank.
    # Within each group keep the most-used arena (most game_days), falling back
    # to lowest id on ties. Reassign game_days then delete the extras.
    arena_rows = execute("SELECT id, name, address FROM arenas").to_a

    groups = arena_rows.group_by do |row|
      [row['name'].to_s.strip.downcase, row['address'].to_s.gsub(/\s+/, ' ').strip.downcase]
    end

    groups.each do |(name_key, address_key), rows|
      next if rows.size < 2
      next if address_key.blank?

      ids = rows.map { |r| r['id'].to_i }

      usage = execute(
        "SELECT arena_id, COUNT(*) AS cnt FROM game_days WHERE arena_id IN (#{ids.join(',')}) GROUP BY arena_id"
      ).each_with_object(Hash.new(0)) { |r, h| h[r['arena_id'].to_i] = r['cnt'].to_i }

      canonical_id = ids.max_by { |id| [usage[id], -id] }
      duplicate_ids = ids - [canonical_id]

      execute("UPDATE game_days SET arena_id = #{canonical_id} WHERE arena_id IN (#{duplicate_ids.join(',')})")
      execute("DELETE FROM arenas WHERE id IN (#{duplicate_ids.join(',')})")

      Rails.logger.info("DeduplicateArenas: kept #{canonical_id}, removed #{duplicate_ids.inspect} (#{name_key})")
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
