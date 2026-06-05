class ApiKey < ApplicationRecord
  has_paper_trail

  validates :name, presence: true
  validates :key_digest, presence: true, uniqueness: true

  after_update :clear_meta_cache
  after_destroy :clear_meta_cache

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

  # Returns cached {rate_limit:, realtime:} for a raw key, or nil if unknown/inactive.
  # Used by Rack::Attack to avoid a DB hit on every request.
  def self.cached_meta(raw_key)
    return nil if raw_key.blank?

    digest = Digest::SHA256.hexdigest(raw_key)
    Rails.cache.fetch("api_key/meta/#{digest}", expires_in: 5.minutes) do
      key = find_by(key_digest: digest, active: true)
      key ? { rate_limit: key.rate_limit, realtime: key.realtime } : nil
    end
  end

  def short_hash
    { id:, name:, active:, rate_limit:, realtime:, created_at:, last_used_at: }
  end

  private

  def clear_meta_cache
    Rails.cache.delete("api_key/meta/#{key_digest}")
  end
end
