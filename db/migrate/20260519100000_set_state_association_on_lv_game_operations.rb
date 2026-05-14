class SetStateAssociationOnLvGameOperations < ActiveRecord::Migration[7.0]
  # Maps game_operation_id → state_association_id for the LV-level game operations.
  # FD (id=1) and SBK Ost (id=6) are national operations and get no SA assignment.
  LV_MAPPING = {
    2  => 2,  # Floorball Niedersachsen
    3  => 3,  # Floorball Verband Berlin-Brandenburg
    4  => 4,  # Floorball-Verband Baden-Württemberg
    5  => 5,  # Floorballverband Schleswig-Holstein
    8  => 8,  # Floorball Verband Hessen
    9  => 9,  # Floorball Verband Bayern
    10 => 10, # Nordrhein-Westfälischer Floorball Verband
    11 => 11, # Rheinland-Pfalz/Saar
  }.freeze

  def up
    LV_MAPPING.each do |go_id, sa_id|
      execute "UPDATE game_operations SET state_association_id = #{sa_id} WHERE id = #{go_id} AND state_association_id IS NULL"
    end
  end

  def down
    go_ids = LV_MAPPING.keys.join(', ')
    execute "UPDATE game_operations SET state_association_id = NULL WHERE id IN (#{go_ids})"
  end
end
