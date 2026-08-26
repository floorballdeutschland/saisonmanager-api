# Lizenz-Dokument eines Spielers (z. B. Ausweiskopie, Zustimmung der
# Erziehungsberechtigten). Dokumente gelten pro Spieler und damit
# saisonübergreifend; license_id ist fachlich nur noch informativ (in
# welchem Antrag wurde hochgeladen), geht aber weiterhin in die
# Eindeutigkeits-Validierung/-Index ein. season_id trägt die
# per_season-Gültigkeit der zugehörigen Dokumentart (DocumentType,
# referenziert über den document_type-Key).
#
# Eine abgelöste Fassung wird nicht mehr gelöscht, sondern archiviert
# (`archived_at`): Der Anhang bleibt abrufbar, damit nachweisbar ist, worauf
# eine erteilte Lizenz beruhte. Aktiv ist je Spieler und Dokumentart weiterhin
# genau eine Zeile – dafür sorgen die Eindeutigkeits-Validierung und der
# partielle Index, beide auf `archived_at IS NULL` eingeschränkt.
class LicenseDocument < ApplicationRecord
  belongs_to :player
  belongs_to :uploaded_by, class_name: 'User', optional: true
  belongs_to :archived_by, class_name: 'User', optional: true
  has_one_attached :file

  ALLOWED_CONTENT_TYPES = %w[application/pdf image/png image/jpeg].freeze
  MAX_FILE_SIZE = 10.megabytes

  # Warum die Fassung nicht mehr die aktuelle ist:
  # 'replaced' – durch einen neuen Upload derselben Dokumentart abgelöst,
  # 'deleted'  – gelöscht, aber als Nachweis aufbewahrt.
  ARCHIVE_REASONS = %w[replaced deleted].freeze

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  validates :document_type, presence: true
  validates :player_id, uniqueness: { scope: %i[license_id document_type],
                                      conditions: -> { where(archived_at: nil) } },
                        unless: :archived?
  validates :archived_reason, inclusion: { in: ARCHIVE_REASONS }, allow_nil: true
  validate :archive_fields_consistent
  validate :file_attached
  validate :file_valid, if: -> { file.attached? }

  def archived?
    archived_at.present?
  end

  # Die Zeile aus dem aktuellen Bestand nehmen, ohne sie oder ihren Anhang zu
  # verlieren. Bewusst ohne Validierung: Ein Datensatz, dessen Blob unterwegs
  # abhandengekommen ist (`file_attached` schlägt dann an), soll trotzdem
  # archivierbar bleiben – sonst hinge er als aktive Fassung fest und blockierte
  # jeden neuen Upload derselben Art.
  def archive!(reason:, user: nil)
    unless ARCHIVE_REASONS.include?(reason)
      raise ArgumentError, "unbekannter Archivierungsgrund: #{reason.inspect}"
    end

    update_columns(archived_at: Time.current, archived_reason: reason,
                   archived_by_id: user&.id, updated_at: Time.current)
  end

  private

  def archive_fields_consistent
    return if archived_at.present? == archived_reason.present?

    errors.add(:archived_reason, 'und archived_at gehören zusammen')
  end

  def file_attached
    errors.add(:file, 'muss hochgeladen werden') unless file.attached?
  end

  def file_valid
    errors.add(:file, 'muss PDF, PNG oder JPEG sein') unless file.content_type.in?(ALLOWED_CONTENT_TYPES)
    errors.add(:file, 'darf maximal 10 MB groß sein') if file.byte_size > MAX_FILE_SIZE
  end
end
