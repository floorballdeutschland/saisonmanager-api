# Prueft eine hochgeladene CSV-Datei, bevor sie geparst wird: Ist sie da, ist
# sie eine Datei, ist sie klein genug, sieht ihr Typ nach CSV aus.
#
# Derselbe Block stand bisher wortgleich in Admin::RefereesController
# (#import_emails) und Admin::RefereeCourseImportsController (#create). Mit dem
# dritten Aufrufer ist die Kopie fuellig genug, um sie zu buendeln — die beiden
# Schiedsrichter-Controller koennen ihre Fassung bei der naechsten Aenderung
# dort ersetzen, ihre Fehlermeldungen sind bewusst nicht angetastet.
module CsvUploadValidation
  MAX_CSV_BYTES = 5 * 1024 * 1024

  # application/octet-stream ist dabei, weil Browser das fuer eine .csv real so
  # schicken (Drag-and-drop, Windows ohne registrierte Zuordnung). Ohne den
  # Eintrag wird eine einwandfreie Datei mit „Unzulaessiger Datei-Typ" abgewiesen,
  # was wie ein kaputter Export aussieht. Der Inhalt wird ohnehin geparst.
  ALLOWED_CSV_CONTENT_TYPES = %w[text/csv text/plain application/vnd.ms-excel application/csv
                                 text/comma-separated-values application/octet-stream].freeze

  private

  # Liefert nil, wenn die Datei brauchbar ist, sonst die Meldung fuer den
  # Aufrufer. Bewusst kein eigenes `render` hier: Die beiden Bestands-Controller
  # antworten unter `error`, die Spielermasken unter `message`, und dieser
  # Unterschied ist Teil ihres Vertrags mit dem Frontend.
  def csv_upload_error(file)
    return 'CSV-Datei fehlt.' if file.blank?
    return 'Der Parameter "file" enthaelt keine Datei.' unless file.respond_to?(:read)

    if file.respond_to?(:size) && file.size > MAX_CSV_BYTES
      return "Datei zu gross (max. #{MAX_CSV_BYTES / 1024 / 1024} MB)."
    end

    content_type = file.respond_to?(:content_type) ? file.content_type.to_s.split(';').first : nil
    return nil if content_type.blank? || ALLOWED_CSV_CONTENT_TYPES.include?(content_type)

    "Unzulaessiger Datei-Typ (#{content_type}). Erwartet wird CSV."
  end
end
