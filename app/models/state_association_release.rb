class StateAssociationRelease < ApplicationRecord
  belongs_to :grantor_state_association, class_name: 'StateAssociation'
  belongs_to :recipient_game_operation, class_name: 'GameOperation'

  validates :season_id, presence: true
  validates :recipient_game_operation_id,
            uniqueness: { scope: %i[grantor_state_association_id season_id] }

  scope :current_season, -> { where(season_id: Setting.current_season_id) }
end
