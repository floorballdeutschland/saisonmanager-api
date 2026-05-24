class TransferRequest < ApplicationRecord
  STATUSES = %w[pending_club pending_player pending_lv scheduled approved
                rejected_by_club rejected_by_player rejected_by_lv revoked withdrawn].freeze

  belongs_to :player
  belongs_to :requesting_club, class_name: 'Club'
  belongs_to :former_club, class_name: 'Club'

  validates :status, inclusion: { in: STATUSES }
  validates :rejection_reason, presence: true, if: -> { status.in?(%w[rejected_by_club rejected_by_lv]) }
  validates :revocation_reason, presence: true, if: -> { status == 'revoked' }

  before_create :generate_player_confirmation_token

  scope :active, -> { where(status: %w[pending_club pending_player pending_lv scheduled]) }
  scope :pending_for_club, ->(club_id) { where(former_club_id: club_id, status: 'pending_club') }
  scope :pending_for_lv, lambda { |go_ids|
    club_ids = go_ids.include?(0) ? Club.pluck(:id) : Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    where(former_club_id: club_ids, status: 'pending_lv')
  }
  scope :for_requesting_club, ->(club_id) { where(requesting_club_id: club_id) }
  scope :for_former_club, ->(club_id) { where(former_club_id: club_id) }

  def as_json(*)
    {
      id:,
      status:,
      request_type:,
      season_id:,
      rejection_reason:,
      revocation_reason:,
      effective_date: effective_date&.iso8601,
      created_at: created_at&.iso8601,
      lv_approved_at: lv_approved_at&.iso8601,
      revoked_at: revoked_at&.iso8601,
      player: player_hash,
      requesting_club: club_hash(requesting_club),
      former_club: club_hash(former_club)
    }
  end

  def execute_transfer!(user_id = nil)
    raise ActiveRecord::RecordInvalid, self unless status.in?(%w[pending_lv scheduled])

    secondary_club_ids = nil

    TransferRequest.transaction do
      lock!
      raise ActiveRecord::RecordInvalid, self unless status.in?(%w[pending_lv scheduled])

      secondary_club_ids = player.clubs.select do |c|
        c['home_club'] == false && c['valid_until'].nil?
      end.map { |c| c['club_id'] }

      invalidate_licenses!
      player.transfer(requesting_club_id, user_id || approved_by_lv_user_id)
      update!(
        status: 'approved',
        approved_by_lv_user_id: approved_by_lv_user_id || user_id,
        lv_approved_at: lv_approved_at || Time.current
      )
    end

    Rails.cache.delete('transfers')
    send_completion_emails(secondary_club_ids)
  end

  def execute_release!(user_id)
    raise ActiveRecord::RecordInvalid, self unless status == 'pending_lv'
    raise ActiveRecord::RecordInvalid, self unless request_type == 'release'

    TransferRequest.transaction do
      add_secondary_club_membership!(user_id)
      update!(
        status: 'approved',
        approved_by_lv_user_id: user_id,
        lv_approved_at: Time.current
      )
    end
  end

  def revoke_release!(user_id, reason)
    raise ActiveRecord::RecordInvalid, self unless status == 'approved'
    raise ActiveRecord::RecordInvalid, self unless request_type == 'release'

    TransferRequest.transaction do
      invalidate_release_licenses!(user_id)
      expire_secondary_club_membership!(user_id)
      update!(
        status: 'revoked',
        revoked_by: user_id,
        revoked_at: Time.current,
        revocation_reason: reason
      )
    end
  end

  private

  def generate_player_confirmation_token
    self.player_confirmation_token = SecureRandom.urlsafe_base64(32)
  end

  def add_secondary_club_membership!(user_id)
    already_member = player.clubs.any? do |c|
      c['club_id'] == requesting_club_id &&
        !c['home_club'] &&
        (c['valid_until'].nil? || c['valid_until'].to_time > Time.now)
    end
    return if already_member

    valid_until = Date.new(Date.today.year, 7, 15).to_time
    valid_until += 1.year if valid_until < Time.now

    player.clubs << {
      'club_id' => requesting_club_id,
      'home_club' => false,
      'created_by' => user_id,
      'valid_set_by' => user_id,
      'created_at' => Time.now,
      'valid_until' => valid_until
    }
    player.save!(validate: false)
  end

  def expire_secondary_club_membership!(user_id)
    player.clubs.map! do |c|
      if c['club_id'] == requesting_club_id && !c['home_club'] &&
         (c['valid_until'].nil? || c['valid_until'].to_time > Time.now)
        c['valid_until'] = Time.now
        c['valid_set_by'] = user_id
      end
      c
    end
    player.save!(validate: false)
  end

  def invalidate_release_licenses!(user_id)
    team_ids = Team.where(club_id: requesting_club_id).pluck(:id).to_set

    player.licenses.each do |license|
      next unless team_ids.include?(license['team_id'].to_i)

      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::WITHDRAWN,
        'reason' => 'Freigabe zurueckgezogen',
        'created_by' => user_id,
        'created_at' => Time.now
      }
    end
    player.save!(validate: false)
  end

  def invalidate_licenses!
    requesting_team_ids = Team.where(club_id: requesting_club_id).pluck(:id).to_set

    player.licenses.each do |license|
      next if requesting_team_ids.include?(license['team_id'].to_i)

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
