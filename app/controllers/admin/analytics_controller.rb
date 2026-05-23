module Admin
  class AnalyticsController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/analytics
    def show
      daily = DailyMetric
              .where(metric_key: 'public_views', date: 30.days.ago.to_date..)
              .order(:date)
              .pluck(:date, :count)

      month_expr = Arel.sql("TO_CHAR(date, 'YYYY-MM')")
      monthly = DailyMetric
                .where(metric_key: 'public_views', date: 12.months.ago.to_date..)
                .group(month_expr)
                .order(month_expr)
                .sum(:count)

      render json: {
        last_30_days: daily.map { |d, c| { date: d, count: c } },
        last_year: monthly.map { |month_str, c| { month: month_str, count: c } }
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
