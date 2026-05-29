module Admin
  class AnalyticsController < ApplicationController
    before_action :authorize_admin!

    DAILY_RANGE_DAYS = 30
    MONTHLY_RANGE_MONTHS = 12

    # GET /api/v2/admin/analytics
    def show
      today = Date.current
      daily_start = today - (DAILY_RANGE_DAYS - 1)
      monthly_start = (today << (MONTHLY_RANGE_MONTHS - 1)).beginning_of_month

      daily_counts = DailyMetric
                     .where(metric_key: 'public_views', date: daily_start..today)
                     .pluck(:date, :count)
                     .to_h

      month_expr = Arel.sql("TO_CHAR(date, 'YYYY-MM')")
      monthly_counts = DailyMetric
                       .where(metric_key: 'public_views', date: monthly_start..today)
                       .group(month_expr)
                       .sum(:count)

      daily = (daily_start..today).map { |d| { date: d, count: daily_counts[d] || 0 } }

      monthly = (0...MONTHLY_RANGE_MONTHS).map do |i|
        month_date = monthly_start >> i
        month_str = month_date.strftime('%Y-%m')
        { month: month_str, count: monthly_counts[month_str] || 0 }
      end

      render json: {
        last_30_days: daily,
        last_year: monthly
      }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
      Rails.logger.error("AnalyticsController#show failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e)
      render json: { error: 'Analysedaten konnten nicht geladen werden.' }, status: :service_unavailable
    end

    private

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
