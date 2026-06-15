class AddLanguageToUsers < ActiveRecord::Migration[7.1]
  # Self-Service-Sprachwahl für den eingeloggten Bereich (DE/EN).
  # Default 'de' hält das Verhalten für Bestandsnutzer unverändert.
  def change
    add_column :users, :language, :string, null: false, default: 'de'
  end
end
