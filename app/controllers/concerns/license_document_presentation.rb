# Gemeinsame Aufbereitung von Lizenz-Dokumenten für die Lizenz-Ansichten:
# Dokumente gelten pro Spieler (saisonübergreifend), nicht mehr pro Lizenz.
# per_season-Dokumentarten zählen nur, wenn der Upload aus der Saison der
# jeweiligen Lizenz stammt.
module LicenseDocumentPresentation
  private

  def license_documents_by_player_and_type(player_ids)
    LicenseDocument.where(player_id: player_ids)
                   .includes(file_attachment: :blob)
                   .group_by { |d| [d.player_id, d.document_type] }
  end

  def document_type_catalog(keys)
    DocumentType.where(key: Array(keys).uniq).index_by(&:key)
  end

  # Map { <typ>: bool, <typ>_url: url } für eine Lizenz. parental_consent ist
  # (wie bisher) immer enthalten.
  def document_map_for(player_id, license_season_id, docs_by_key, required_keys, catalog)
    result = {}
    (%w[parental_consent] | Array(required_keys)).each do |key|
      doc = current_document(player_id, key, license_season_id, docs_by_key, catalog)
      result[key.to_sym] = doc.present?
      result["#{key}_url".to_sym] =
        doc && doc.file.attached? ? rails_blob_url(doc.file, disposition: 'inline') : nil
    end
    result
  end

  def current_document(player_id, key, license_season_id, docs_by_key, catalog)
    docs = docs_by_key[[player_id, key]] || []
    docs = docs.select { |d| d.season_id.to_s == license_season_id.to_s } if catalog[key]&.per_season?
    docs.max_by(&:created_at)
  end

  # Zeitpunkt der Lizenzbeantragung (Stichtag für altersabhängige Dokumente).
  def license_requested_at(license)
    entry = Array(license && license['history']).find { |h| h['license_status_id'].to_i == License::REQUESTED }
    entry && entry['created_at']&.to_time
  rescue ArgumentError
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
      template_url: document_type.template.attached? ? rails_blob_url(document_type.template, disposition: 'attachment') : nil
    }
  end
end
