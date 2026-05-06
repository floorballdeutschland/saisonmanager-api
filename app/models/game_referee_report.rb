class GameRefereeReport < ApplicationRecord
  belongs_to :game
  belongs_to :uploaded_by, class_name: 'User'

  has_one_attached :file

  validates :file, presence: true
  validate :acceptable_file

  private

  def acceptable_file
    return unless file.attached?

    unless file.content_type.in?(%w[application/pdf image/png image/jpeg])
      errors.add(:file, 'muss PDF, PNG oder JPEG sein')
    end

    if file.byte_size > 5.megabytes
      errors.add(:file, 'darf maximal 5 MB groß sein')
    end
  end
end
