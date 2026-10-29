# Tages-Aggregat der Zugriffe anonymer Website-Besucher (PublicSession) je
# Endpunkt. Gegenstück zu ApiKeyUsage, nur ohne Key: Bis die Sitzung den
# Frontend-Key ablöste, stand dieser Verkehr in dessen Statistik.
class PublicSessionUsage < ApplicationRecord
  # Wie ApiKeyUsage.increment!: ein Upsert pro Request, Fehler werden
  # geschluckt, weil Zählen einen ausgelieferten Request nie scheitern lassen
  # darf.
  def self.increment!(endpoint:, date: Date.current)
    upsert(
      { date: date, endpoint: endpoint, count: 1, created_at: Time.current, updated_at: Time.current },
      unique_by: %i[date endpoint],
      on_duplicate: Arel.sql('count = public_session_usages.count + 1, updated_at = EXCLUDED.updated_at')
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.error("PublicSessionUsage.increment! failed endpoint=#{endpoint}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end
end
