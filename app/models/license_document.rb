class LicenseDocument < ApplicationRecord
  belongs_to :player
  belongs_to :uploaded_by, class_name: 'User', optional: true
  has_one_attached :file

  ALLOWED_CONTENT_TYPES = %w[application/pdf image/png image/jpeg].freeze
  MAX_FILE_SIZE = 10.megabytes

  validates :license_id, presence: true
  validates :document_type, presence: true
  validates :player_id, uniqueness: { scope: %i[license_id document_type] }
  validate :file_attached
  validate :file_valid, if: -> { file.attached? }

  private

  def file_attached
    errors.add(:file, 'muss hochgeladen werden') unless file.attached?
  end

  def file_valid
    errors.add(:file, 'muss PDF, PNG oder JPEG sein') unless file.content_type.in?(ALLOWED_CONTENT_TYPES)
    errors.add(:file, 'darf maximal 10 MB groß sein') if file.byte_size > MAX_FILE_SIZE
  end
end
