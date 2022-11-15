class License < ApplicationRecord
  APPROVED = 1
  REQUESTED = 2
  DENIED = 3
  DELETED = 4
  DELETE_REQUESTED = 5
  TRANSFER = 6
  IGNORED = 7
  WITHDRAWN = 8

  NAMES = {
    License::APPROVED => 'erteilt',
    License::REQUESTED => 'beantragt',
    License::DENIED => 'abgelehnt',
    License::DELETED => 'ungültig: gelöscht',
    License::DELETE_REQUESTED => 'ungültig: Löschung beantragt',
    License::TRANSFER => 'ungültig wg. Transfer',
    License::IGNORED => 'ungültig: ignoriert',
    License::WITHDRAWN => 'zurückgezogen'
  }.freeze
end
