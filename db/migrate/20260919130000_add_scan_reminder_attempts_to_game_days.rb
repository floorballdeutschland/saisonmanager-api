class AddScanReminderAttemptsToGameDays < ActiveRecord::Migration[7.2]
  # Zaehlt die fehlgeschlagenen Versuche. Ein einzelner Fehlschlag (Greylisting,
  # Mailserver kurz weg) darf die Erinnerung nicht dauerhaft loeschen, eine
  # kaputte Adresse den Verein aber auch nicht stuendlich in denselben Fehler
  # laufen lassen.
  #
  # Bewusst eine eigene Migration und nicht in 20260919120000 nachgetragen: Wer
  # die Vorfassung schon migriert hatte, haette die Spalte nie bekommen --
  # `db:migrate` schweigt zu einem bereits eingetragenen Zeitstempel, und der
  # Fehler faellt erst beim ersten fehlgeschlagenen Versand auf, also genau in
  # dem Moment, fuer den diese Spalte da ist.
  def change
    add_column :game_days, :scan_reminder_attempts, :integer, null: false, default: 0
  end
end
