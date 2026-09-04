class License < ApplicationRecord
  APPROVED = 1
  REQUESTED = 2
  DENIED = 3
  DELETED = 4
  # Die 5 hieß 'ungültig: Löschung beantragt' und ist ersatzlos entfallen: kein
  # Schreibweg im Code und auf Produktiv kein einziger Datensatz – weder als
  # aktueller Status noch irgendwo in einer History. Das Altsystem kannte den
  # Zwischenschritt „Verein beantragt die Löschung, Verband bestätigt"; heute zieht
  # der Verein selbst zurück (WITHDRAWN) oder der Verband löscht (DELETED). Der
  # Legacy-Import bildet die alte 5 deshalb auf WITHDRAWN ab, siehe
  # LegacyImport::Vocab::LIZENZSTATUS_TO_STATUS_ID. Die Zahl wird nicht neu vergeben.
  TRANSFER = 6
  # Reiner Altbestand. Auf Produktiv tragen ihn 545 Lizenzen (Stand 04.09.2026),
  # ausnahmslos ohne season_id, ohne reason und mit dem jüngsten Eintrag aus 2022 –
  # alle aus dem Altsystem, das damit eine erteilte Lizenz stilllegte, ohne sie zu
  # löschen. Im neuen Code gibt es keinen Schreibweg und soll keiner entstehen: Der
  # Status existiert nur noch, damit diese Lizenzen einen Namen haben statt einer
  # nackten 7.
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

  # Jüngster History-Eintrag = aktueller Status. Über den Zeitstempel und nicht
  # über die Position im Array: Angehängt wird die History an vielen Stellen,
  # sortiert ist sie nirgends garantiert.
  def self.current_status_id(license)
    license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
  end

  # Die eine Stelle, an der steht, welche Lizenz sich löschen lässt. Player#full_hash
  # setzt danach das Kennzeichen `delete_allowed` für den Knopf im Profil,
  # PlayersController#handle_license_request lehnt danach ab. Fielen die beiden
  # auseinander, böte die Oberfläche einen Knopf an, der in ein 422 läuft.
  #
  # Bewusst eng: nur die laufende Saison – eine abgerechnete Saison rührt niemand
  # per Klick an – und nur ein aktiver Status. „Gelöscht" auf eine bereits
  # abgelehnte, zurückgezogene oder für einen Transfer ungültige Lizenz zu legen,
  # benennt nur den Endzustand um, ohne etwas zu ändern.
  def self.deletable?(license, current_season_id = Setting.current_season_id)
    return false if license.blank?
    return false unless license['season_id'].to_s == current_season_id.to_s

    ACTIVE_STATUSES.include?(current_status_id(license))
  end

  # Meldung, warum sich die Lizenz nicht löschen lässt – oder nil, wenn nichts
  # dagegen spricht.
  #
  # Die Begründung ist Pflicht und steht bewusst neben der Regel: Das Löschen ist
  # der einzige Weg, auf dem eine erteilte Lizenz aus der Vereinsansicht
  # verschwindet, ohne dass ein Vorgang dahinterstünde, den man nachlesen könnte.
  # Der Freitext IST die Begründung. Er landet in der History und über die
  # Gebührenrechnung, die jede Lizenz der Saison mitsamt History exportiert
  # (Player#main_license_hash → select_license, ohne Statusfilter), auch bei der
  # Abrechnungsstelle: Eine gelöschte Lizenz fällt nicht aus der Gebühr, und das
  # soll sie auch nicht – sonst wäre der Knopf ein Weg daran vorbei.
  def self.delete_blocked_reason(license, reason, current_season_id = Setting.current_season_id)
    return 'Lizenz nicht gefunden.' if license.blank?
    return 'Zum Löschen einer Lizenz ist eine Begründung erforderlich.' if reason.to_s.strip.blank?
    return nil if deletable?(license, current_season_id)

    if license['season_id'].to_s == current_season_id.to_s
      'Nur erteilte oder beantragte Lizenzen lassen sich löschen.'
    else
      'Es lassen sich nur Lizenzen der laufenden Saison löschen.'
    end
  end

  NAMES = {
    License::APPROVED => 'erteilt',
    License::REQUESTED => 'beantragt',
    License::DENIED => 'abgelehnt',
    License::DELETED => 'ungültig: gelöscht',
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
