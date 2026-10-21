class GameScan < ApplicationRecord
  include PdfOnlyAttachment

  belongs_to :game
  belongs_to :uploaded_by, class_name: 'User', optional: true
  has_one_attached :scan_file

  MAX_FILE_SIZE = 5.megabytes

  validates :expires_at, presence: true
  validates :game_id, uniqueness: true
  validate :scan_file_attached
  validate :scan_file_valid, if: -> { scan_file.attached? }

  scope :active, -> { where('expires_at > ?', Time.current) }

  private

  def scan_file_attached
    errors.add(:scan_file, 'muss hochgeladen werden') unless scan_file.attached?
  end

  def scan_file_valid
    validate_pdf_attachment(:scan_file, max_size: MAX_FILE_SIZE)
  end
end
