class AddRskEmailToStateAssociations < ActiveRecord::Migration[7.1]
  def change
    add_column :state_associations, :rsk_email, :string,
               comment: 'Postfach für Schiedsrichteransetzungen über den Saisonmanager'
  end
end
