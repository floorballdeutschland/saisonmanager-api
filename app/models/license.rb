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
    License::DELETED => 'gelöscht',
    License::DELETE_REQUESTED => 'Löschung beantragt',
    License::TRANSFER => 'Transfer',
    License::IGNORED => 'ignoriert',
    License::WITHDRAWN => 'zurückgezogen'
  }.freeze
end
