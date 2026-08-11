# Partnerlogos für die Livestream-Overlays.
#
# Zwei Ebenen, wie entschieden: Der Verband pflegt die Partner der LIGA, der
# Verein die seines eigenen Vereins. Auf Sendung laufen beide Sätze reihum
# durch dieselbe Fläche. Das ist eher eine Frage der Vermarktungsrechte als der
# Technik, und deshalb liegen die Logos auch dort, wo die Rechte liegen: an der
# Liga beziehungsweise am Verein.
#
# Mehrere Anhänge statt eines Feldes, weil ein Wettbewerb in der Regel mehrere
# Partner hat und die Fläche zwischen ihnen wechselt.
module SponsorLogos
  extend ActiveSupport::Concern

  # Obergrenze je Ebene. Nicht willkürlich: Bei fester Standzeit je Partner
  # bestimmt die Zahl, wie lange ein einzelnes Logo auf sich warten lässt. Acht
  # Partner à fünf Sekunden sind schon vierzig Sekunden bis zur Wiederholung.
  MAX_SPONSOR_LOGOS = 8

  included do
    has_many_attached :sponsor_logos
  end

  # Reihenfolge ist die des Hochladens. Das `order(:id)` ist dafür nötig und nicht
  # bloß Zierde: `has_many_attached` deklariert die Verknüpfung OHNE Sortierung,
  # die Abfrage käme also unsortiert zurück und Postgres liefert, was der Plan
  # gerade hergibt — in der Praxis oft nach `blob_id` statt nach `id`. Das fällt
  # meist zusammen, zugesagt ist es nie, und auf dieser Reihenfolge steht die
  # Rotation der Fläche auf Sendung.
  #
  # `includes(:blob)`, weil sowohl `filename` als auch die Adresse über `signed_id`
  # an den Blob delegieren: ohne Vorladen eine Abfrage je Logo, und der
  # Overlay-Abruf rendert beide Ebenen zusammen.
  #
  # Wer die Reihenfolge ändern will, löscht und lädt neu — ein eigenes Sortierfeld
  # wäre eine Spalte und eine Oberfläche mehr für einen Handgriff, den ein Verein
  # einmal im Jahr macht.
  def sponsor_logo_hashes
    sponsor_logos_attachments.includes(:blob).order(:id).map do |attachment|
      {
        id: attachment.id,
        url: Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true),
        filename: attachment.filename.to_s
      }
    end
  end

  def sponsor_logo_urls
    sponsor_logo_hashes.pluck(:url)
  end

  # `.size` statt `.attached? && .count`: `attached?` lädt die Verknüpfung, `count`
  # setzte danach noch ein eigenes COUNT(*) hinterher.
  def sponsor_logo_limit_reached?
    sponsor_logos_attachments.size >= MAX_SPONSOR_LOGOS
  end
end
