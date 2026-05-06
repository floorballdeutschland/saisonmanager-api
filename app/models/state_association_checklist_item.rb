class StateAssociationChecklistItem < ApplicationRecord
  belongs_to :state_association

  validates :question, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  default_scope { order(:position, :id) }
end
