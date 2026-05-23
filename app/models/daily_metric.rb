class DailyMetric < ApplicationRecord
  def self.increment!(key, date = Date.current)
    upsert(
      { date: date, metric_key: key, count: 1, created_at: Time.current, updated_at: Time.current },
      unique_by: [:date, :metric_key],
      on_duplicate: Arel.sql('count = daily_metrics.count + 1, updated_at = EXCLUDED.updated_at')
    )
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    Rails.logger.error("DailyMetric.increment! failed key=#{key} date=#{date}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e)
  end
end
