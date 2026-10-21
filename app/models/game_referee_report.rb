class GameRefereeReport < ApplicationRecord
  include PdfOnlyAttachment

  belongs_to :game
  belongs_to :uploaded_by, class_name: 'User'

  has_one_attached :file

  MAX_FILE_SIZE = 5.megabytes

  validates :file, presence: true
  validate :acceptable_file

  private

  def acceptable_file
    validate_pdf_attachment(:file, max_size: MAX_FILE_SIZE)
  end
end
