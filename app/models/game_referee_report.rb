class GameRefereeReport < ApplicationRecord
  include PdfOnlyAttachment

  belongs_to :game
  belongs_to :uploaded_by, class_name: 'User'

  has_one_attached :file

  validates :file, presence: true
  validate :acceptable_file

  private

  def acceptable_file
    return unless file.attached?

    validate_new_pdf_attachment(:file)

    if file.byte_size > 5.megabytes
      errors.add(:file, 'darf maximal 5 MB groß sein')
    end
  end
end
