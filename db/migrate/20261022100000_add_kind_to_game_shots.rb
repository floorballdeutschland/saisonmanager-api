# Tabletmodus: Freischläge (fe#589).
#
# Freischläge liegen als eigene Art in `game_shots` statt in einer eigenen
# Tabelle: gleiche Grunddaten (Team, Abschnitt, Spielzeit, Antippen, Position)
# und derselbe idempotente Weg über `client_uuid`, damit Puffer und Abgleich
# des Tablets unverändert bleiben. Ein Freischlag hat kein Ergebnis, `result`
# wird deshalb nullbar; das Modell verlangt es weiter für jeden Schuss.
class AddKindToGameShots < ActiveRecord::Migration[7.2]
  def change
    change_table :game_shots, bulk: true do |t|
      t.string :kind, null: false, default: 'shot', comment: 'shot / free_hit'
      t.boolean :from_free_hit, null: false, default: false,
                                comment: 'Schuss aus einem Freischlag (am Tablet geschaltet)'
    end
    change_column_null :game_shots, :result, true
    change_column_comment :game_shots, :team,
                          from: 'home / guest: das schießende Team',
                          to: 'home / guest: das schießende bzw. den Freischlag ausführende Team'
    change_column_comment :game_shots, :result,
                          from: 'goal / saved / missed / blocked',
                          to: 'goal / saved / missed / blocked, leer bei Freischlägen'
  end
end
