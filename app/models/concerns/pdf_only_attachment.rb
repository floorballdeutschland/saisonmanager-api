# Spieldokumente (Scan des Spielberichtsbogens, Berichtsformular der
# Schiedsrichter) nehmen nur noch PDF an. Fotos ließen sich in der
# Browseransicht nicht drehen, die SBK musste jedes hochkant fotografierte
# Blatt erst herunterladen.
#
# Geprüft wird nur ein NEU angehängtes Dokument. Vorher hochgeladene Fotos
# bleiben gültig und abrufbar: Ein Bestandsdatensatz, der aus anderem Grund
# gespeichert wird, darf an der neuen Regel nicht scheitern.
#
# Der content_type allein reicht nicht, er kommt aus dem Multipart-Kopf des
# Uploads. ActiveStorage korrigiert ihn nur bei Dateien mit bekannten Magic
# Bytes (ein Foto wird wieder zu image/png), eine Datei ohne solche Kennung
# behält den angegebenen Typ. Deshalb zusätzlich die PDF-Kennung `%PDF-` im
# Dateikopf. Die Spezifikation erlaubt Vorspann davor, Acrobat sucht sie in
# den ersten 1024 Bytes, also hier genauso.
#
# Falscher Typ und zu große Datei ergeben dieselbe Meldung, und zwar auf
# :base: Die Controller geben `full_messages` aus, und am Attribut stünde der
# Spaltenname davor („Scan file muss …“). Wer ein Foto oder ein zu großes PDF
# hochlädt, soll in beiden Fällen lesen, was zulässig ist.
module PdfOnlyAttachment
  extend ActiveSupport::Concern

  PDF_CONTENT_TYPE = 'application/pdf'.freeze
  PDF_SIGNATURE = '%PDF-'.b.freeze
  SIGNATURE_WINDOW = 1024

  class_methods do
    def pdf_only_message(max_size)
      "Nur PDF-Dateien bis #{max_size / 1.megabyte} MB sind zulässig, Fotos werden nicht angenommen."
    end
  end

  private

  # Die Größe gilt wie bisher für jedes Speichern, das Format nur für ein neu
  # angehängtes Dokument.
  def validate_pdf_attachment(name, max_size:)
    attachment = public_send(name)
    return unless attachment.attached?

    return unless new_attachment_not_pdf?(name, attachment) || attachment.byte_size > max_size

    errors.add(:base, self.class.pdf_only_message(max_size))
  end

  def new_attachment_not_pdf?(name, attachment)
    change = attachment_changes[name.to_s]
    return false if change.nil?

    !(attachment.content_type == PDF_CONTENT_TYPE && pdf_signature?(change.attachable) != false)
  end

  # true/false, wenn sich der Dateikopf lesen lässt, sonst nil. Ein
  # unlesbares Attachable (etwa eine signierte Blob-ID) prüft dann nur der
  # content_type; die Controller hängen ausschließlich Uploads an.
  def pdf_signature?(attachable)
    io = attachable.is_a?(Hash) ? attachable[:io] : attachable
    return nil unless io.respond_to?(:read) && io.respond_to?(:rewind)

    head = io.read(SIGNATURE_WINDOW).to_s.b
    io.rewind
    head.include?(PDF_SIGNATURE)
  end
end
