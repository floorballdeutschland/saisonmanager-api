class StateAssociationRelease < ApplicationRecord
  belongs_to :grantor_state_association, class_name: 'StateAssociation'
  belongs_to :recipient_game_operation, class_name: 'GameOperation'

  validates :recipient_game_operation_id, uniqueness: { scope: :grantor_state_association_id }
end
