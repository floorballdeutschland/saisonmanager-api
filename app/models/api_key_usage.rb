# Tages-Aggregat der Zugriffe eines API-Keys je Endpunkt. Grundlage für die
# Nutzungsansicht in der Key-Verwaltung und damit für die Frage, wo Rate-Limits
# nötig sind (§ 6 der Nutzungsvereinbarung).
class ApiKeyUsage < ApplicationRecord
  belongs_to :api_key

  # Ein einzelner Upsert pro Request, nach dem Muster von DailyMetric#increment!.
  # Fehler werden geschluckt: Zählen darf einen ausgelieferten Request niemals
  # nachträglich scheitern lassen.
  def self.increment!(api_key_id:, endpoint:, date: Date.current)
    upsert(
      { api_key_id: api_key_id, date: date, endpoint: endpoint, count: 1,
        created_at: Time.current, updated_at: Time.current },
      unique_by: %i[api_key_id date endpoint],
      on_duplicate: Arel.sql('count = api_key_usages.count + 1, updated_at = EXCLUDED.updated_at')
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.error(
      "ApiKeyUsage.increment! failed api_key_id=#{api_key_id} endpoint=#{endpoint}: #{e.class}: #{e.message}"
    )
    Sentry.capture_exception(e) if defined?(Sentry)
  end
end
