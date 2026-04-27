class AddRefereeIdToUsers < ActiveRecord::Migration[7.0]
  def change
    add_reference :users, :referee, foreign_key: true, null: true
  end
end
