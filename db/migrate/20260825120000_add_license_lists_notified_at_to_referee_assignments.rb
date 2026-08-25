class AddLicenseListsNotifiedAtToRefereeAssignments < ActiveRecord::Migration[7.2]
  def change
    # Idempotenz-Marke für den wöchentlichen Lizenzlisten-Versand
    # (RefereeLicenseListNotifier): gesetzt, sobald die Lizenzlisten zu dieser
    # Ansetzung verschickt wurden — sei es im Wochenlauf oder direkt beim
    # Veröffentlichen einer kurzfristigen Ansetzung.
    add_column :referee_assignments, :license_lists_notified_at, :datetime
  end
end
