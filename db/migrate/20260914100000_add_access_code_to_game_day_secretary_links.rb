# Kurzcode zum Abtippen am Hallenrechner. Beide Spalten sind nullable: Links,
# die vor dieser Migration ausgegeben wurden, haben keinen Code und laufen mit
# ihrem Token aus (72 Stunden).
class AddAccessCodeToGameDaySecretaryLinks < ActiveRecord::Migration[7.2]
  def change
    add_column :game_day_secretary_links, :code_digest, :string
    add_column :game_day_secretary_links, :code_salt, :string
    add_index :game_day_secretary_links, :code_digest, unique: true
  end
end
