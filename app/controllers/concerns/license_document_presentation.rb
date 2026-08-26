# Gemeinsame Aufbereitung von Lizenz-Dokumenten für die Lizenz-Ansichten:
# Dokumente gelten pro Spieler (saisonübergreifend), nicht mehr pro Lizenz.
# per_season-Dokumentarten zählen nur, wenn der Upload aus der Saison der
# jeweiligen Lizenz stammt.
module LicenseDocumentPresentation
  private

  # Nur die aktive Fassung: Archivierte Zeilen (abgeloest oder geloescht, aber
  # als Nachweis aufbewahrt) sind kein aktueller Nachweis. Ohne den Filter
  # meldete die Genehmigungsuebersicht ein geloeschtes Dokument weiter als
  # vorhanden.
  def license_documents_by_player_and_type(player_ids)
    LicenseDocument.active
                   .where(player_id: player_ids)
                   .includes(file_attachment: :blob)
                   .group_by { |d| [d.player_id, d.document_type] }
  end

  def document_type_catalog(keys)
    DocumentType.where(key: Array(keys).uniq).index_by(&:key)
  end

  # Pflichtdokumente einer Liga, bevor sie über DocumentType.required_keys nach
  # Alter aufgelöst werden. Die Elternzustimmung kommt aus zwei Quellen: dem
  # Liga-Flag parental_consent_required und (falls die SBK sie ausdrücklich
  # eingetragen hat) required_documents. Ohne beides ist sie nicht gefordert –
  # vorher zeigten die Lizenzansichten sie bundesweit bei jeder minderjährigen
  # Person an, unabhängig davon, ob die Liga sie überhaupt verlangt.
  def league_required_document_keys(league)
    keys = Array(league.required_documents)
    keys |= %w[parental_consent] if league.parental_consent_required
    keys
  end

  # Map { <typ>: bool, <typ>_url: url, <typ>_uploaded_at: zeitpunkt } für eine
  # Lizenz. parental_consent ist (wie bisher) immer enthalten.
  #
  # _uploaded_at hängt an derselben Bedingung wie _url: Ohne abrufbare Datei
  # soll auch kein Datum erscheinen, sonst wiese die Genehmigungsübersicht einen
  # Upload aus, den dort niemand öffnen kann. Als Zeitpunkt zählt created_at des
  # Dokuments, nicht das des Anhangs – ein erneuter Upload löscht den bisherigen
  # Datensatz und legt einen neuen an (Admin::LicenseDocumentsController#create),
  # created_at ist damit stets der Zeitpunkt des aktuellen Uploads.
  def document_map_for(player_id, license_season_id, docs_by_key, required_keys, catalog)
    result = {}
    (%w[parental_consent] | Array(required_keys)).each do |key|
      doc = current_document(player_id, key, license_season_id, docs_by_key, catalog)
      attached = doc&.file&.attached?

      # Ein Datensatz ohne Anhang ist ein Defekt (verlorener Blob, abgebrochener
      # Upload) und die Ansichten melden dafür „fehlt", während der Datensatz
      # weiterbesteht. Ohne Spur würde daraus still eine falsche Aussage über den
      # Verein, deshalb hier die einzige Stelle, an der das auffallen kann.
      if doc.present? && !attached
        Rails.logger.warn(
          "LicenseDocument #{doc.id} (Spieler #{player_id}, #{key}) ohne Anhang – " \
          'die Lizenzansichten melden das Dokument als fehlend'
        )
      end

      result[key.to_sym] = doc.present?
      result["#{key}_url".to_sym] =
        attached ? rails_blob_url(doc.file, disposition: 'inline') : nil
      # iso8601 wie bei jedem anderen Zeitstempel im Projekt: Ein roher
      # TimeWithZone hinge am Framework-Vorgabeformat, und ein anderes Format
      # ließe die date-Pipe im Frontend werfen statt nur diese Zelle leer zu
      # lassen.
      result["#{key}_uploaded_at".to_sym] = attached ? doc.created_at&.iso8601 : nil
    end
    result
  end

  def current_document(player_id, key, license_season_id, docs_by_key, catalog)
    docs = docs_by_key[[player_id, key]] || []
    docs = docs.select { |d| d.season_id.to_s == license_season_id.to_s } if catalog[key]&.per_season?
    docs.max_by(&:created_at)
  end

  # Zeitpunkt der Lizenzbeantragung (Stichtag für altersabhängige Dokumente).
  # Bewusst der LETZTE REQUESTED-Eintrag – konsistent zu requested_at in
  # League#licenses (nach Rückzug + Neuantrag zählt der aktuelle Antrag). Ohne
  # lesbares Antragsdatum greift in DocumentType.required_keys der Fallback auf
  # das heutige Datum.
  #
  # Nicht mehr konsistent zur Karenzzeit: License.grace_period_anchor überspringt
  # seit api#554 Einträge aus Verwaltungskorrekturen. Hier bleibt der jüngste
  # Antrag maßgeblich, auch ein korrigierter – ob die Altersgrenze eines
  # Pflichtdokuments nach einer Korrektur neu gerechnet werden soll, ist eine
  # eigene fachliche Frage und ausdrücklich nicht mit entschieden.
  def license_requested_at(license)
    entry = Array(license && license['history'])
            .select { |h| h['license_status_id'].to_i == License::REQUESTED }
            .max_by { |h| h['created_at'].to_s }
    entry && entry['created_at']&.to_time
  rescue ArgumentError
    Rails.logger.warn("license_requested_at: unlesbares created_at in Lizenz #{license && license['id']}")
    nil
  end

  def document_type_json(document_type)
    {
      id: document_type.id,
      key: document_type.key,
      name: document_type.name,
      description: document_type.description,
      game_operation_id: document_type.game_operation_id,
      validity: document_type.validity,
      required_below_age: document_type.required_below_age,
      required_from_birth_year: document_type.required_from_birth_year,
      template_url: document_type.template.attached? ? rails_blob_url(document_type.template, disposition: 'attachment') : nil
    }
  end
end
