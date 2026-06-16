class AddTelefonnummerToReferees < ActiveRecord::Migration[7.1]
  def change
    add_column :referees, :telefonnummer, :string
  end
end
