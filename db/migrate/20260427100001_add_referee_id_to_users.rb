class AddRefereeIdToUsers < ActiveRecord::Migration[7.0]
  def change
    add_reference :users, :referee, foreign_key: true, null: true
    add_index :users, :referee_id, unique: true, where: 'referee_id IS NOT NULL', name: 'index_users_on_referee_id_unique'
  end
end
