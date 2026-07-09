class RemoveWalletPassFromReferees < ActiveRecord::Migration[7.1]
  # Die Passmeister-Wallet-Anbindung (digitaler Schiedsrichterausweis als
  # Apple-/Google-Wallet-Pass) wurde entfernt – abgelöst durch den digitalen
  # Schiri-Ausweis im Schiri-Portal. Neben den beiden Spalten wird eine ggf.
  # gepflegte E-Mail-Vorlage der entfernten Mailer-Action gelöscht: Ihr
  # Katalog-Eintrag existiert nicht mehr, der Datensatz wäre in der Admin-UI
  # weder sichtbar noch pflegbar. Irreversibel by design – die Pass-URLs
  # verweisen auf einen gekündigten Passmeister-Account.
  def up
    remove_column :referees, :wallet_pass_issued_at
    remove_column :referees, :wallet_pass_url

    execute <<~SQL.squish
      DELETE FROM email_templates
      WHERE mailer_class = 'RefereeMailer' AND action_name = 'wallet_pass_issued'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
