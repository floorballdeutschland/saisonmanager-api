class ApiKey < ApplicationRecord
  has_paper_trail

  validates :name, presence: true
  validates :key_digest, presence: true, uniqueness: true

  def self.generate(name:)
    raw_key = SecureRandom.hex(32)
    api_key = new(name: name, key_digest: Digest::SHA256.hexdigest(raw_key))
    if api_key.save
      [raw_key, api_key]
    else
      Rails.logger.error("ApiKey.generate failed: #{api_key.errors.full_messages}")
      [nil, api_key]
    end
  end

  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    key_digest = Digest::SHA256.hexdigest(raw_key)
    api_key = find_by(key_digest: key_digest, active: true)
    api_key&.update_column(:last_used_at, Time.current)
    api_key
  end

  def short_hash
    { id: id, name: name, active: active, created_at: created_at, last_used_at: last_used_at }
  end
end
