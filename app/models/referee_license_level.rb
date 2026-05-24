class RefereeLicenseLevel < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  scope :ordered, -> { order(:position, :name) }

  def usage_count
    Referee.where(lizenzstufe: name).count
  end
end
