# Tabletmodus: Strafschüsse und Torwartsituation am Schuss (Feedback #61, #63, #64).
#
# Wie `from_free_hit` schaltet das Tablet die Kennungen, die API speichert und
# zählt nur. `empty_net` und `extra_attacker` beschreiben die Torwartsituation
# beim Schuss aus Sicht des schießenden Teams: aufs leere Tor des Gegners bzw.
# mit herausgenommenem eigenem Torhüter (6 gegen 5). Beide können zugleich
# gelten. Der normale Spielbericht (`games.events`) bleibt davon unberührt.
#
# Paraden ohne Feldposition (Feedback #62) brauchen keine Spalte: `x` und `y`
# sind schon nullbar, das Modell lässt sie bei gehaltenen Schüssen weg.
class AddSituationFlagsToGameShots < ActiveRecord::Migration[7.2]
  def change
    change_table :game_shots, bulk: true do |t|
      t.boolean :from_penalty_shot, null: false, default: false,
                                    comment: 'Strafschuss (am Tablet geschaltet)'
      t.boolean :empty_net, null: false, default: false,
                            comment: 'Schuss aufs leere Tor: Gegner ohne Torhüter'
      t.boolean :extra_attacker, null: false, default: false,
                                 comment: 'Schießendes Team ohne eigenen Torhüter (6 gegen 5)'
    end
  end
end
