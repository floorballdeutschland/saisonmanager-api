class AddVskSbkEmailToStateAssociations < ActiveRecord::Migration[7.0]
  def change
    add_column :state_associations, :vsk_email, :string
    add_column :state_associations, :sbk_email, :string
  end
end
