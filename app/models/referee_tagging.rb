class RefereeTagging < ApplicationRecord
  belongs_to :referee
  belongs_to :referee_tag

  validates :referee_id, uniqueness: { scope: :referee_tag_id,
                                       message: 'hat diesen Tag bereits' }
end
