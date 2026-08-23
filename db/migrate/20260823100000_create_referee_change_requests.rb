# Anträge der Schiedsrichter auf Korrektur ihrer Stammdaten (Vorname, Nachname,
# Geburtsdatum, Verein). Diese vier Felder pflegt das Schiri-Profil bewusst
# nicht selbst: Der Name steht auf dem digitalen Ausweis, und der Verein
# entscheidet über Zuständigkeit und Ansetzbarkeit. Bisher blieb dem Schiri nur
# der Weg über eine Mail an den Verband; der Antrag hier bildet denselben
# Vorgang nachvollziehbar ab, analog zu den Spielerprofilen
# (player_change_requests).
class CreateRefereeChangeRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :referee_change_requests do |t|
      t.references :referee, null: false, foreign_key: true
      t.string :correction_type, null: false,
                                 comment: 'vorname, nachname, geburtsdatum oder verein'
      # Neuer Wert der Textfelder, beim Geburtsdatum als ISO-Datum (JJJJ-MM-TT).
      # Beim Vereinswechsel steht der Zielverein stattdessen in new_club_id,
      # damit die Anzeige den Namen nicht aus einer Zahl nachschlagen muss und
      # ein gelöschter Verein nicht als Zahl im Antrag stehen bleibt.
      t.string :new_value
      t.bigint :new_club_id
      t.string :reason, limit: 200
      t.string :status, null: false, default: 'pending'
      t.string :decision_note, limit: 200
      t.integer :requested_by_user_id
      t.integer :reviewed_by_user_id
      t.datetime :decided_at

      t.timestamps
    end

    add_index :referee_change_requests, :status
    # Pro Schiri und Feld nur ein offener Antrag; entschiedene Anträge bleiben
    # als Historie erhalten.
    add_index :referee_change_requests, %i[referee_id correction_type],
              unique: true,
              where: "status = 'pending'",
              name: 'index_referee_change_requests_pending_unique'
    add_foreign_key :referee_change_requests, :clubs, column: :new_club_id
  end
end
