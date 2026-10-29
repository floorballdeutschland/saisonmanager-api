class ApiKey < ApplicationRecord
  has_paper_trail

  # Zugriffe werden pro Tag und Endpunkt aggregiert; mit dem Key verschwindet
  # auch seine Statistik. Der zugehörige Antrag bleibt als Vorgang erhalten und
  # verliert nur die Verknüpfung, sonst blockiert der Fremdschlüssel das Löschen.
  has_many :api_key_usages, dependent: :delete_all
  has_one :api_key_application, dependent: :nullify

  # Genauigkeit, mit der last_used_at nachgeführt wird. Ohne diese Grenze
  # schrieb jeder einzelne Request die Spalte neu; für die Anzeige „zuletzt
  # genutzt" genügt Minutengenauigkeit, und die Schreiblast bleibt beim Zählen
  # der Zugriffe (ApiKeyUsage) statt beim Zeitstempel.
  LAST_USED_PRECISION = 1.minute

  # Zusatzpakete, die nur ausdrücklich freigegebene Schlüssel abrufen dürfen
  # (ApplicationController#require_api_feature!). Sie werden individuell
  # vereinbart und von Hand in der Verwaltung gesetzt, nie über den Antrag.
  # - detailed_stats: ausführliche Statistik eines Spiels (games/:id/detailed_stats)
  # - league_shot_stats: Schussstatistik einer Liga über alle Tabletspiele
  #   (leagues/:id/shot_stats); die Website zeigt sie nicht
  FEATURES = %w[detailed_stats league_shot_stats].freeze

  validates :name, presence: true
  validates :key_digest, presence: true, uniqueness: true
  validate :features_known

  before_validation { self.features = Array(features).compact_blank.map(&:to_s).uniq }

  after_update :clear_meta_cache
  after_destroy :clear_meta_cache

  # rate_limit ist die Grenze in Anfragen pro Minute; nil heißt unbegrenzt und
  # bleibt der Vorgabewert für die von Hand angelegten Keys (Prerender-Build,
  # Partner; bis 2026-10 auch das eigene Frontend, das sich seitdem über eine
  # anonyme Sitzung ausweist, siehe PublicSession). Zugänge aus dem Antragsprozess bekommen die Grenze aus
  # § 6.1 der Nutzungsvereinbarung mitgegeben, siehe ApiKeyApplication#reveal_key!.
  def self.generate(name:, rate_limit: nil)
    raw_key = SecureRandom.hex(32)
    api_key = new(name: name, key_digest: Digest::SHA256.hexdigest(raw_key), rate_limit: rate_limit)
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
    api_key&.touch_last_used
    api_key
  end

  def touch_last_used
    return if last_used_at.present? && last_used_at > LAST_USED_PRECISION.ago

    update_column(:last_used_at, Time.current)
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

  def feature?(name)
    features.include?(name.to_s)
  end

  def short_hash
    { id:, name:, active:, rate_limit:, realtime:, features:, created_at:, last_used_at: }
  end

  private

  def features_known
    unknown = features - FEATURES
    errors.add(:features, "unbekannt: #{unknown.join(', ')}") if unknown.any?
  end

  def clear_meta_cache
    Rails.cache.delete("api_key/meta/#{key_digest}")
  end
end
