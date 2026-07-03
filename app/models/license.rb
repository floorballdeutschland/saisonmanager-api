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

  # Frühester Genehmigungszeitpunkt (APPROVED) eines Lizenz-Hashes als Tiebreaker
  # für die Haupt-/Zusatzlizenz-Bestimmung (license_type) bei gleicher Ligastufe:
  # die zeitlich früher genehmigte Lizenz gewinnt. ISO8601-Strings sind
  # lexikografisch = chronologisch vergleichbar. Ohne Genehmigung wird ein ferner
  # Zeitpunkt zurückgegeben, damit solche Lizenzen nicht als Hauptlizenz gewinnen.
  def self.approval_time(license)
    approvals = Array(license && license['history'])
                .select { |h| h['license_status_id'].to_i == APPROVED }
                .filter_map { |h| h['created_at'] }
    approvals.min || '9999-12-31T23:59:59Z'
  end
end
