module Admin
  class ApiKeysController < ApplicationController
    before_action :authorize_admin!
    before_action :set_api_key, only: %i[update destroy usage]

    USAGE_DAILY_RANGE_DAYS = 30
    USAGE_MONTHLY_RANGE_MONTHS = 12

    # GET /api/v2/admin/api_keys
    def index
      keys = ApiKey.includes(:api_key_application).order(created_at: :desc).to_a

      # Zugriffe der letzten 30 Tage für alle Keys in einer Abfrage, damit die
      # Liste nicht pro Zeile nachzählt.
      totals = ApiKeyUsage.where(date: usage_daily_start..Date.current)
                          .group(:api_key_id).sum(:count)

      render json: keys.map { |key| key_json(key, totals) }
    end

    # GET /api/v2/admin/api_keys/:id/usage
    # Aufbau bewusst identisch zu Admin::AnalyticsController#show, damit das
    # Frontend dessen Diagramm-Darstellung wiederverwenden kann.
    def usage
      today = Date.current
      monthly_start = (today << (USAGE_MONTHLY_RANGE_MONTHS - 1)).beginning_of_month
      scope = @api_key.api_key_usages

      daily_counts = scope.where(date: usage_daily_start..today).group(:date).sum(:count)
      month_expr = Arel.sql("TO_CHAR(date, 'YYYY-MM')")
      monthly_counts = scope.where(date: monthly_start..today).group(month_expr).sum(:count)

      render json: {
        last_30_days: (usage_daily_start..today).map { |d| { date: d, count: daily_counts[d] || 0 } },
        last_year: (0...USAGE_MONTHLY_RANGE_MONTHS).map do |i|
          month_str = (monthly_start >> i).strftime('%Y-%m')
          { month: month_str, count: monthly_counts[month_str] || 0 }
        end,
        by_endpoint: scope.where(date: usage_daily_start..today)
                          .group(:endpoint).sum(:count)
                          .sort_by { |_endpoint, count| -count }
                          .map { |endpoint, count| { endpoint: endpoint, count: count } },
        rate_limit: @api_key.rate_limit,
        name: @api_key.name
      }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
      Rails.logger.error("Admin::ApiKeysController#usage failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      render json: { error: 'Nutzungsdaten konnten nicht geladen werden.' }, status: :service_unavailable
    end

    # POST /api/v2/admin/api_keys
    # rate_limit wird durchgereicht, weil api_key_params es erlaubt; ohne Angabe
    # bleibt es nil und der Key ungedrosselt, wie bisher.
    def create
      raw_key, api_key = ApiKey.generate(name: api_key_params[:name],
                                         rate_limit: api_key_params[:rate_limit].presence)
      if raw_key && api_key.persisted?
        render json: api_key.short_hash.merge(raw_key: raw_key), status: :created
      else
        render json: { errors: api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /api/v2/admin/api_keys/:id
    def update
      if @api_key.update(api_key_params.slice(:active, :rate_limit, :realtime))
        render json: @api_key.short_hash
      else
        render json: { errors: @api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/api_keys/:id
    def destroy
      @api_key.destroy
      head :no_content
    end

    private

    def usage_daily_start
      Date.current - (USAGE_DAILY_RANGE_DAYS - 1)
    end

    # Zusätzlich zum short_hash die Nutzung der letzten 30 Tage und, sofern der
    # Key aus einem Antrag entstanden ist, wer dahintersteht. Manuell angelegte
    # Keys haben keinen Antrag, application bleibt dann leer.
    def key_json(key, totals)
      application = key.api_key_application
      key.short_hash.merge(
        usage_30_days: totals[key.id] || 0,
        application: application && {
          id: application.id,
          organisation: application.organisation,
          contact_name: application.contact_name,
          email: application.email
        }
      )
    end

    def set_api_key
      @api_key = ApiKey.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'API-Key nicht gefunden' }, status: :not_found
    end

    def api_key_params
      params.require(:api_key).permit(:name, :active, :rate_limit, :realtime)
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
