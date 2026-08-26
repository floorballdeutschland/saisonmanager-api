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

  # Markierung an einem `beantragt`-Eintrag, der aus dem Widerruf einer Ablehnung
  # stammt und deshalb das kostenfreie Zeitfenster nicht neu startet.
  REVOKED_REJECTION_KEY = 'revoked_rejection'.freeze

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

  # Der `beantragt`-Eintrag, ab dem das kostenfreie Zeitfenster läuft – oder nil,
  # wenn es keinen gibt.
  #
  # Übersprungen werden Einträge aus dem Widerruf einer Ablehnung: Der Antrag ist
  # dann Wochen alt und längst kostenpflichtig, der Widerruf korrigiert nur einen
  # Irrtum der SBK. Ohne diese Ausnahme eröffnete jeder Widerruf ein neues
  # Gratis-Fenster, und ein Zurückziehen darin löscht die Lizenz ersatzlos – samt
  # der Historie der irrtümlichen Ablehnung, die gerade der Beleg dafür ist.
  #
  # Eine Wiedereinstellung durch den Verein selbst (reenable_license_request)
  # trägt die Markierung NICHT und eröffnet weiterhin ein Fenster: Dort stellt der
  # Verein tatsächlich neu und soll den Irrtum genauso zurücknehmen können wie
  # beim ersten Antrag.
  #
  # Bleibt nichts übrig, ist das Ergebnis nil und der Aufrufer behandelt den Fall
  # wie eine abgelaufene Frist – kostenpflichtig. Das ist die sichere Richtung:
  # Ein Altbestand ohne lesbaren Antragszeitpunkt darf keine Gratis-Löschung
  # auslösen.
  def self.grace_period_anchor(history)
    Array(history)
      .select { |h| h['license_status_id'].to_i == REQUESTED && !h[REVOKED_REJECTION_KEY] }
      .max_by { |h| h['created_at'] }
  end

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
