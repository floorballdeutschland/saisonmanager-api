# Request-gebundene Zwischenspeicher.
#
# ActiveSupport setzt die Attribute vor jedem Request und vor jedem Testfall
# zurueck. Damit koennen die Werte nicht veralten, anders als bei Rails.cache:
# Der Cache-Store ist in Produktion `:memory_store`, also je Puma-Worker eigen.
# Eine Leerung nach einer Aenderung erreicht nur den Worker, der die Aenderung
# entgegengenommen hat, alle anderen behielten den alten Stand bis zum Ablauf der
# Standzeit. Fuer die Zustaendigkeitsableitung am Verein waere das eine falsche
# Berechtigung auf Zeit.
#
# Gespeichert wird hier nur, was innerhalb EINES Requests vielfach gebraucht wird
# und sich darin nicht aendert:
#
#   setting                                   die Setting-Konfiguration, an 75
#                                             Stellen gelesen; ein
#                                             Rails-Cache-Treffer kostet je
#                                             Aufruf ein Marshal.load des ganzen
#                                             AR-Objekts (siehe Setting.current)
#   state_association_tree                    der Verbandsbaum (Wurzeln, Teilbaeume)
#   game_operation_id_by_state_association    Spielbetrieb je Landesverband
#   game_operations_by_id                     die Spielbetriebe selbst, nach ID
#
# Die beiden mittleren loesen `Club#main_game_operation_id` auf, das in den
# Vereins- und Spielerlisten je Datensatz laeuft. Das letzte haelt die
# vollstaendigen Datensaetze fuer `Club#home_game_operation`, das in den
# Lizenzlisten je Zeile den Namen braucht. Bei rund zehn Spielbetrieben ist das
# unkritisch; eine groessere Tabelle gehoerte hier nicht hinein.
#
# Grenze der Zusicherung: Zurueckgesetzt wird vor jedem Request und per
# `after_commit`. Eine Strukturaenderung INNERHALB einer noch offenen Transaktion
# ist fuer den Rest derselben Transaktion also unsichtbar. Heute liest kein Pfad
# den Baum zwischen Schreiben und Commit.
class Current < ActiveSupport::CurrentAttributes
  attribute :setting

  attribute :state_association_tree
  attribute :game_operation_id_by_state_association
  attribute :game_operations_by_id

  # Aufzurufen, wenn ein Request die Verbandsstruktur selbst aendert. Ohne das
  # arbeitete der Rest desselben Requests mit dem Stand von vorher. Die Haken
  # sitzen in StateAssociation und GameOperation.
  #
  # `setting` bleibt bewusst unberuehrt: Die Verbandsstruktur steht nicht im
  # Setting, und Setting.current hat seine eigene Invalidierung.
  def self.reset_association_structure
    self.state_association_tree = nil
    self.game_operation_id_by_state_association = nil
    self.game_operations_by_id = nil
  end
end
