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
# und sich darin nicht aendert: der Verbandsbaum und die Spielbetriebe je
# Landesverband. Beide zusammen loesen `Club#main_game_operation_id` auf, das in
# den Vereins- und Spielerlisten je Datensatz laeuft.
class Current < ActiveSupport::CurrentAttributes
  attribute :state_association_tree
  attribute :game_operation_id_by_state_association

  # Aufzurufen, wenn ein Request die Verbandsstruktur selbst aendert. Ohne das
  # arbeitete der Rest desselben Requests mit dem Stand von vorher.
  def self.reset_association_structure
    self.state_association_tree = nil
    self.game_operation_id_by_state_association = nil
  end
end
