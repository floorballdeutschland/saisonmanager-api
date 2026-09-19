class AddScanReminderSentAtToGameDays < ActiveRecord::Migration[7.2]
  def change
    add_column :game_days, :scan_reminder_sent_at, :datetime
    # Zaehlt die fehlgeschlagenen Versuche. Ein einzelner Fehlschlag (Greylisting,
    # Mailserver kurz weg) darf die Erinnerung nicht dauerhaft loeschen, eine
    # kaputte Adresse den Verein aber auch nicht stuendlich in denselben Fehler
    # laufen lassen.
    add_column :game_days, :scan_reminder_attempts, :integer, null: false, default: 0
  end
end
