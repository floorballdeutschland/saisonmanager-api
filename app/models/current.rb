# Request-gebundene Zwischenspeicher.
#
# ActiveSupport setzt die Attribute vor jedem Request und vor jedem Testfall
# zurueck. Damit koennen die Werte nicht veralten, anders als bei Rails.cache:
# Der Cache-Store ist in Produktion `:memory_store`, also je Puma-Worker eigen.
# Eine Leerung nach einer Aenderung erreicht nur den Worker, der die Aenderung
# entgegengenommen hat, alle anderen behielten den alten Stand bis zum Ablauf der
# Standzeit.
#
# Gespeichert wird hier nur, was innerhalb EINES Requests vielfach gebraucht wird
# und sich darin nicht aendert: die Setting-Konfiguration, die an 75 Stellen
# gelesen wird und deren Rails-Cache-Treffer je Aufruf ein Marshal.load des
# ganzen AR-Objekts kostet (siehe Setting.current).
class Current < ActiveSupport::CurrentAttributes
  attribute :setting
end
