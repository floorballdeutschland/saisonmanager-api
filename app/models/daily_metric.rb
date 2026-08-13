class DailyMetric < ApplicationRecord
  def self.increment!(key, date = Date.current)
    upsert(
      { date: date, metric_key: key, count: 1, created_at: Time.current, updated_at: Time.current },
      unique_by: %i[date metric_key],
      on_duplicate: Arel.sql('count = daily_metrics.count + 1, updated_at = EXCLUDED.updated_at')
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.error("DailyMetric.increment! failed key=#{key} date=#{date}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e)
  end

  # Tageswert setzen statt hochzählen: für Kennzahlen, die einen Zustand messen
  # (z. B. die Plattenbelegung in Prozent) und nicht Ereignisse zählen. Ein
  # erneuter Lauf am selben Tag überschreibt den Wert.
  def self.set!(key, value, date = Date.current)
    upsert(
      { date: date, metric_key: key, count: value.to_i, created_at: Time.current, updated_at: Time.current },
      unique_by: %i[date metric_key],
      on_duplicate: Arel.sql('count = EXCLUDED.count, updated_at = EXCLUDED.updated_at')
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.error("DailyMetric.set! failed key=#{key} date=#{date}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e)
  end
end
