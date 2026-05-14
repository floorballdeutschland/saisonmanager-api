class DropArenaDisabledColumn < ActiveRecord::Migration[7.0]
  def up
    remove_column :arenas, :disabled
  end

  def down
    add_column :arenas, :disabled, :boolean, default: false
  end
end
