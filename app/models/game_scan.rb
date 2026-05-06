class GameScan < ApplicationRecord
  belongs_to :game
  belongs_to :uploaded_by, class_name: 'User', optional: true
  has_one_attached :scan_file

  ALLOWED_CONTENT_TYPES = %w[application/pdf image/png image/jpeg].freeze
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
    unless scan_file.content_type.in?(ALLOWED_CONTENT_TYPES)
      errors.add(:scan_file, 'muss PDF, PNG oder JPEG sein')
    end
    if scan_file.byte_size > MAX_FILE_SIZE
      errors.add(:scan_file, 'darf maximal 5 MB groß sein')
    end
  end
end
