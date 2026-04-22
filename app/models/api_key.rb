class ApiKey < ApplicationRecord
  validates :name, presence: true
  validates :key_digest, presence: true, uniqueness: true

  def self.generate(name:)
    raw_key = SecureRandom.hex(32)
    key_digest = Digest::SHA256.hexdigest(raw_key)
    api_key = new(name: name, key_digest: key_digest)
    api_key.save
    [raw_key, api_key]
  end

  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    key_digest = Digest::SHA256.hexdigest(raw_key)
    find_by(key_digest: key_digest, active: true)
  end

  def short_hash
    { id: id, name: name, active: active, created_at: created_at }
  end
end
