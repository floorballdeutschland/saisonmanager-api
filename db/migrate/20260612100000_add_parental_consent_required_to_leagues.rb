class AddParentalConsentRequiredToLeagues < ActiveRecord::Migration[7.1]
  def change
    add_column :leagues, :parental_consent_required, :boolean, default: false, null: false
  end
end
