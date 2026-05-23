module Admin
  class AnalyticsController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/analytics
    def show
      last_30 = DailyMetric
        .where(metric_key: 'public_views', date: 30.days.ago.to_date..)
        .order(:date)
        .pluck(:date, :count)

      last_year = DailyMetric
        .where(metric_key: 'public_views', date: 12.months.ago.to_date..)
        .group("DATE_TRUNC('month', date)")
        .order("DATE_TRUNC('month', date)")
        .sum(:count)

      render json: {
        last_30_days: last_30.map { |d, c| { date: d, count: c } },
        last_year: last_year.map { |m, c| { month: m.strftime('%Y-%m'), count: c } }
      }
    end

    private

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
