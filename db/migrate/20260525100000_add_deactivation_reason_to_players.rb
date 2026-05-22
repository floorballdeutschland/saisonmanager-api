class AddDeactivationReasonToPlayers < ActiveRecord::Migration[7.0]
  def change
    add_column :players, :deactivation_reason, :string
  end
end
