class GameDaySecretaryLink < ApplicationRecord
  belongs_to :game_day
  belongs_to :created_by, class_name: 'User'

  scope :active, -> { where('expires_at > ?', Time.current) }

  def self.find_by_token(raw_token)
    digest = Digest::SHA256.hexdigest(raw_token)
    active.find_by(token_digest: digest)
  end

  def self.generate!(game_day:, created_by:)
    raw_token = SecureRandom.urlsafe_base64(32)
    digest = Digest::SHA256.hexdigest(raw_token)

    where(game_day:).destroy_all

    link = create!(
      game_day: game_day,
      created_by: created_by,
      token_digest: digest,
      expires_at: 72.hours.from_now
    )

    [link, raw_token]
  end
end
