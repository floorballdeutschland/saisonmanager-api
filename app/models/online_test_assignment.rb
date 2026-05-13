class OnlineTestAssignment < ApplicationRecord
  belongs_to :online_test
  belongs_to :referee

  validates :assigned_at, presence: true
  validates :referee_id, uniqueness: { scope: :online_test_id }

  def to_hash
    {
      id:,
      online_test_id:,
      referee_id:,
      referee_name: "#{referee.nachname}, #{referee.vorname}",
      lizenznummer: referee.lizenznummer,
      lizenzstufe: referee.lizenzstufe,
      assigned_at: assigned_at.iso8601
    }
  end
end
