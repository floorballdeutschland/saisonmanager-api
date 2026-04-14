class StateAssociation < ApplicationRecord
  validates :name, presence: true

  def short_hash
    { id:, name:, short_name: }
  end
end
