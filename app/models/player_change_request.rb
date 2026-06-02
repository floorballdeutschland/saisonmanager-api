class PlayerChangeRequest < ApplicationRecord
  CORRECTION_TYPES = %w[birthdate first_name last_name names_swapped nationality gender].freeze
  STATUSES = %w[pending approved rejected].freeze

  belongs_to :player
  belongs_to :club

  validates :correction_type, inclusion: { in: CORRECTION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :new_value, presence: true, unless: -> { correction_type == 'names_swapped' }
  validates :new_value, inclusion: { in: %w[M W D] }, if: -> { correction_type == 'gender' }
  validates :rejection_reason, presence: true, if: -> { status == 'rejected' }

  scope :pending, -> { where(status: 'pending') }
  scope :for_club, ->(club_id) { where(club_id: club_id) }
  scope :for_go, lambda { |go_ids|
    club_ids = go_ids.include?(0) ? Club.pluck(:id) : Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    where(club_id: club_ids)
  }

  def apply!(reviewed_by_user_id)
    case correction_type
    when 'birthdate'
      player.update!(birthdate: new_value)
    when 'first_name'
      player.update!(first_name: new_value)
    when 'last_name'
      player.update!(last_name: new_value)
    when 'names_swapped'
      player.update!(first_name: player.last_name, last_name: player.first_name)
    when 'nationality'
      player.update!(nation_id: new_value.to_i)
    when 'gender'
      player.update!(gender: new_value)
    end

    update!(status: 'approved', reviewed_by_user_id: reviewed_by_user_id)
  end

  def as_json(*)
    {
      id:,
      correction_type:,
      new_value:,
      status:,
      rejection_reason:,
      created_at: created_at&.iso8601,
      player: {
        id: player.id,
        first_name: player.first_name,
        last_name: player.last_name,
        birthdate: player.birthdate,
        nation_id: player.nation_id
      },
      club: { id: club.id, name: club.name },
      requested_by_user_id:,
      reviewed_by_user_id:
    }
  end
end
