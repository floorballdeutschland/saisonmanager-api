class RefereeTag < ApplicationRecord
  belongs_to :game_operation, optional: true
  has_many :referee_taggings, dependent: :destroy
  has_many :referees, through: :referee_taggings

  validates :name, presence: true,
                   length: { maximum: 24 },
                   uniqueness: { scope: :game_operation_id, case_sensitive: false }

  # Sichtbarer Tag-Bestand für einen Ansetzer/RSK mit Verbands-Scope: die Tags
  # der eigenen Spielbetriebe plus die globalen (game_operation_id IS NULL).
  scope :for_game_operations, lambda { |go_ids|
    where(game_operation_id: go_ids).or(where(game_operation_id: nil))
  }
end
