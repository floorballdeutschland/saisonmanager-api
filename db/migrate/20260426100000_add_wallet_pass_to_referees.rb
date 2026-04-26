class AddWalletPassToReferees < ActiveRecord::Migration[7.0]
  def change
    add_column :referees, :wallet_pass_issued_at, :datetime
    add_column :referees, :wallet_pass_url, :string
  end
end
