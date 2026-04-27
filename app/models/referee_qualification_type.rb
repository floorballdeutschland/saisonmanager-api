class RefereeQualificationType < ApplicationRecord
  has_many :referee_qualifications, dependent: :destroy

  validates :name, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
end
