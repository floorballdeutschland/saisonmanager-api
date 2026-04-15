class AddEmailToPlayers < ActiveRecord::Migration[7.0]
  def change
    add_column :players, :email, :string
  end
end
