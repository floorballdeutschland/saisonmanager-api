module Admin
  # Rechnungsexport der Schiedsrichterkurse (RefereeCourseBilling). Jeder LV
  # exportiert fuer sich: Eine LV-RSK sieht und exportiert nur ihre
  # Landesverbaende, Admin und FD-RSK zusaetzlich die bundesweiten Kurse
  # (state_association_id leer bzw. „national").
  class RefereeCourseBillingExportsController < ApplicationController
    before_action :set_policy
    before_action :set_state_association, only: %i[preview create]
    before_action :set_export, only: :download

    # GET /api/v2/admin/referee_course_billing_exports
    def index
      exports = RefereeCourseBillingExport.includes(:state_association, :created_by_user).order(created_at: :desc)
      ids = @policy.state_association_ids
      unless ids == :all
        exports = exports.where(state_association_id: ids)
      end
      render json: exports.limit(100).map(&:summary_hash)
    end

    # GET /api/v2/admin/referee_course_billing_exports/preview
    def preview
      billing = build_billing
      rows = billing.rows
      render json: {
        headers: billing.headers,
        rows: rows.map do |row|
          { registration_id: row.registration.id, values: billing.csv_values(row), warnings: row.warnings }
        end,
        row_count: rows.size,
        total_cents: billing.total_cents,
        waiting_for_license: billing.waiting_for_license.map { |r| "#{r.vorname} #{r.nachname}" }
      }
    end

    # POST /api/v2/admin/referee_course_billing_exports
    # Immer ohne include_billed: Abgerechnetes laesst sich in der Vorschau
    # ansehen und ueber den alten Export erneut herunterladen, aber nicht ein
    # zweites Mal abrechnen.
    def create
      billing = build_billing(include_billed: false)
      return render json: { error: 'Nichts abzurechnen' }, status: :unprocessable_entity if billing.rows.empty?

      export = billing.create!(user: current_user)
      render json: export.summary_hash, status: :created
    rescue RefereeCourseBilling::StaleRows => e
      render json: { error: e.message }, status: :conflict
    end

    # GET /api/v2/admin/referee_course_billing_exports/:id/download
    def download
      return render json: { error: 'Datei fehlt' }, status: :not_found unless @export.file.attached?

      send_data @export.file.download, filename: @export.file.filename.to_s, type: 'text/csv; charset=utf-8'
    end

    private

    def set_policy
      @policy = RefereeCoursePolicy.new(current_user)
      render json: { error: 'Nicht berechtigt' }, status: :forbidden unless @policy.any_access?
    end

    # „national" (oder leer) heisst bundesweite Kurse und bleibt Admin/FD-RSK
    # vorbehalten (RefereeCoursePolicy#assign_state_association?).
    def set_state_association
      raw = params[:state_association_id]
      @state_association_id = raw.blank? || raw == 'national' ? nil : raw.to_i
      return if @policy.assign_state_association?(@state_association_id)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def set_export
      @export = RefereeCourseBillingExport.find_by(id: params[:id])
      return render(json: { error: 'Export nicht gefunden' }, status: :not_found) if @export.nil?

      ids = @policy.state_association_ids
      return if ids == :all || ids.include?(@export.state_association_id)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def build_billing(include_billed: ActiveModel::Type::Boolean.new.cast(params[:include_billed]) == true)
      RefereeCourseBilling.new(
        state_association_id: @state_association_id,
        from: parse_date(params[:from]), to: parse_date(params[:to]),
        include_billed: include_billed
      )
    end

    def parse_date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end
  end
end
