# Gemeinsame Serialisierung der Stammdaten-Korrekturanträge für das Profil und
# den Selfservice-Endpunkt. Beide liefern denselben Ausschnitt, damit die Maske
# nach dem Anlegen oder Zurückziehen keine zweite Abfrage braucht.
module RefereeChangeRequestPresenter
  extend ActiveSupport::Concern

  private

  def change_requests_json(referee)
    referee.referee_change_requests
           .includes(:new_club, :referee)
           .order(created_at: :desc)
           .map(&:as_json)
  end
end
