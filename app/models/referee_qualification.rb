class RefereeQualification < ApplicationRecord
  belongs_to :referee
  belongs_to :referee_qualification_type

  validates :referee_id, uniqueness: { scope: :referee_qualification_type_id,
                                       message: 'hat diese Qualifikation bereits' }
end
