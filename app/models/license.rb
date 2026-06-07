class License < ApplicationRecord
  APPROVED = 1
  REQUESTED = 2
  DENIED = 3
  DELETED = 4
  DELETE_REQUESTED = 5
  TRANSFER = 6
  IGNORED = 7
  WITHDRAWN = 8
  SUSPENDED = 9

  # Status, die als "aktiv" gelten (spielberechtigt oder beantragt) und durch eine
  # Sperre ausgesetzt werden können.
  ACTIVE_STATUSES = [APPROVED, REQUESTED].freeze

  # Zeitfenster, in dem ein beantragter Lizenzantrag kostenfrei (= ersatzlose Löschung
  # statt Status WITHDRAWN) zurückgezogen werden kann.
  GRACE_PERIOD = 1.hour

  NAMES = {
    License::APPROVED => 'erteilt',
    License::REQUESTED => 'beantragt',
    License::DENIED => 'abgelehnt',
    License::DELETED => 'ungültig: gelöscht',
    License::DELETE_REQUESTED => 'ungültig: Löschung beantragt',
    License::TRANSFER => 'ungültig wg. Transfer',
    License::IGNORED => 'ungültig: ignoriert',
    License::WITHDRAWN => 'zurückgezogen',
    License::SUSPENDED => 'gesperrt'
  }.freeze
end
