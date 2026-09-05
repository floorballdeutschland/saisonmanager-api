# Spielbetriebs-Grenze des Wettbewerbs-Geltungsbereichs (#604).
#
# Der Wettbewerb ist Altersklasse plus Feldgroesse plus Wettbewerbsgruppe. Das
# allein reicht nicht: Bundesliga und Regionalliga sind beide "Herren
# Grossfeld, Ligaspielbetrieb", liegen aber in verschiedenen Spielbetrieben,
# und die SBK hat ihre Weisungsbefugnis nur im eigenen. Ohne diese Spalte
# haette eine Sperre der SBK FD still auch die Ligen der Landesverbaende
# erfasst.
#
# NULL heisst ausdruecklich "alle Spielbetriebe" und bleibt der
# Bundesadministration vorbehalten.
class AddGameOperationToPlayerSuspensions < ActiveRecord::Migration[7.2]
  def change
    add_column :player_suspensions, :game_operation_id, :bigint
  end
end
