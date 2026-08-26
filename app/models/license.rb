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

  # Markierung an einem `beantragt`-Eintrag, der aus einer Verwaltungskorrektur
  # stammt (Admin/SBK über handle_license_request) und deshalb die Karenzzeit
  # nicht neu startet. Der Name stammt vom ersten Anlass, dem Widerruf einer
  # Ablehnung; gesetzt wird er inzwischen für jeden Weg über diesen Endpunkt.
  #
  # Der Wert landet in JSONB und ist damit Bestandsdaten: Wird er geändert,
  # gelten alle vorhandenen Markierungen als nicht gesetzt und die Lücke ist
  # wieder offen. Ein Test hält ihn deshalb fest.
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

  # Der `beantragt`-Eintrag, ab dem die Karenzzeit läuft – oder nil, wenn es
  # keinen gibt.
  #
  # Gezählt wird nur die erste Beantragung einer Lizenz, also der Eintrag aus
  # PlayersController#request_license. Alles, was danach wieder auf `beantragt`
  # setzt, ist markiert und zählt nicht: die Verwaltungskorrektur von Admin oder
  # SBK (handle_license_request), das Wiedereinstellen durch den Verein
  # (reenable_license_request) und der zurückgeschriebene Status nach Ablauf
  # einer Sperre (Player#lift_suspension!).
  #
  # Ohne diese Unterscheidung eröffnete jeder dieser Wege ein neues
  # Gratis-Fenster, und ein Zurückziehen darin löscht die Lizenz ersatzlos – samt
  # der Historie, die sie kostenpflichtig macht. Kostenfrei löschen kann damit
  # nur, wer den Antrag gerade selbst gestellt hat.
  #
  # Die Markierung hängt am Weg, nicht am Statuswechsel: Sie wird beim Schreiben
  # gesetzt, weil nur dort bekannt ist, wer handelt und warum.
  #
  # Maßgeblich bleibt der Zeitpunkt des Antrags selbst: Lehnt die SBK innerhalb
  # der ersten Stunde ab und widerruft gleich darauf, liegt der ursprüngliche
  # Antrag noch in seinem eigenen Fenster und das Zurückziehen bleibt kostenfrei.
  #
  # Einträge ohne verwertbaren Zeitpunkt fallen heraus (Altdaten-Import baut die
  # Historie mit `compact`, `created_at` kann fehlen). Bleibt dadurch nichts
  # übrig, ist das Ergebnis nil: withdraw_license_request setzt dann WITHDRAWN,
  # also kostenpflichtig, und die Vereinsansicht liefert kein Fristende. Das ist
  # die sichere Richtung – ein unlesbarer Antragszeitpunkt darf keine
  # Gratis-Löschung auslösen, und ohne den Filter würfe `max_by` hier.
  def self.grace_period_anchor(history)
    Array(history)
      .select { |h| h['license_status_id'].to_i == REQUESTED && !h[REVOKED_REJECTION_KEY] }
      .reject { |h| h['created_at'].blank? }
      .max_by { |h| h['created_at'].to_s }
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
