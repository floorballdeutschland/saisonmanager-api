class TransferRequest < ApplicationRecord
  STATUSES = %w[pending_club pending_lv approved rejected_by_club rejected_by_lv].freeze

  belongs_to :player
  belongs_to :requesting_club, class_name: 'Club'
  belongs_to :former_club, class_name: 'Club'

  validates :status, inclusion: { in: STATUSES }
  validates :rejection_reason, presence: true, if: -> { status.in?(%w[rejected_by_club rejected_by_lv]) }

  scope :active, -> { where(status: %w[pending_club pending_lv]) }
  scope :pending_for_club, ->(club_id) { where(former_club_id: club_id, status: 'pending_club') }
  scope :pending_for_lv, lambda { |go_ids|
    joins('INNER JOIN clubs ON clubs.id = transfer_requests.former_club_id')
      .where("clubs.game_operations_hash @> ANY(ARRAY[?]::jsonb[])",
             go_ids.map { |id| [{ game_operation_id: id, home_game_operation: true }].to_json })
      .where(status: 'pending_lv')
  }
  scope :for_requesting_club, ->(club_id) { where(requesting_club_id: club_id) }
  scope :for_former_club, ->(club_id) { where(former_club_id: club_id) }

  def as_json(*)
    {
      id:,
      status:,
      season_id:,
      rejection_reason:,
      created_at: created_at&.iso8601,
      player: player_hash,
      requesting_club: club_hash(requesting_club),
      former_club: club_hash(former_club)
    }
  end

  def execute_transfer!(user_id)
    secondary_club_ids = player.clubs.select do |c|
      c['home_club'] == false && c['valid_until'].nil?
    end.map { |c| c['club_id'] }

    invalidate_licenses!
    player.transfer(requesting_club_id, user_id)

    update!(
      status: 'approved',
      approved_by_lv_user_id: user_id,
      lv_approved_at: Time.current
    )

    send_completion_emails(secondary_club_ids)
  end

  private

  def invalidate_licenses!
    player.licenses.each do |license|
      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::TRANSFER,
        'reason' => 'Transfer',
        'created_by' => nil,
        'created_at' => Time.now
      }
    end
    player.save!(validate: false)
  end

  def send_completion_emails(secondary_club_ids)
    TransferRequestMailer.transfer_completed(self).deliver_later

    if requesting_club.state_association_id != former_club.state_association_id
      TransferRequestMailer.transfer_completed_receiving_lv(self).deliver_later
    end

    secondary_club_ids.each do |club_id|
      club = Club.find_by(id: club_id)
      next unless club&.contact_email.present?

      TransferRequestMailer.secondary_club_notification(self, club).deliver_later
    end
  end

  def player_hash
    {
      id: player.id,
      first_name: player.first_name,
      last_name: player.last_name,
      birthdate: player.birthdate
    }
  end

  def club_hash(club)
    { id: club.id, name: club.name }
  end
end
