module Admin
  # Verwaltung der Strafcodes (z. B. "902 - Stockschlag"). Strafcodes liegen als
  # JSONB-Hash in Setting#penalty_codes, keyed by id-String. Die id (= Key) wird
  # von historischen Spiel-Ereignissen über penalty_code_id referenziert und darf
  # NIE neu vergeben/umindiziert werden – neue Einträge bekommen max(id)+1.
  # Der 3-stellige Code ist ein reines Anzeigefeld und nicht die id.
  class PenaltyCodesController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/penalty_codes
    # Liefert alle Codes (auch inaktive) für die Verwaltung, sortiert nach Code.
    def index
      render json: serialize(penalty_codes)
    end

    # POST /api/v2/admin/penalty_codes
    def create
      code = params.dig(:penalty_code, :code).to_s.strip
      description = params.dig(:penalty_code, :description).to_s.strip

      error = validation_error(code, description)
      return render json: { error: error }, status: :unprocessable_entity if error

      codes = penalty_codes
      new_id = next_id(codes)
      codes[new_id] = { 'code' => code, 'description' => description, 'active' => true }
      persist(codes)

      render json: entry_json(new_id, codes[new_id]), status: :created
    end

    # PUT /api/v2/admin/penalty_codes/:id
    def update
      codes = penalty_codes
      id = params[:id].to_s
      return render json: { error: 'Strafcode nicht gefunden' }, status: :not_found unless codes.key?(id)

      entry = codes[id]
      code = params.dig(:penalty_code, :code)&.to_s&.strip || entry['code']
      description = params.dig(:penalty_code, :description)&.to_s&.strip || entry['description']

      error = validation_error(code, description, ignore_id: id)
      return render json: { error: error }, status: :unprocessable_entity if error

      entry['code'] = code
      entry['description'] = description
      active_param = params.dig(:penalty_code, :active)
      entry['active'] = ActiveModel::Type::Boolean.new.cast(active_param) unless active_param.nil?
      codes[id] = entry
      persist(codes)

      render json: entry_json(id, entry)
    end

    # DELETE /api/v2/admin/penalty_codes/:id
    # Entfernt den Eintrag. Andere ids bleiben unverändert (keine Umindizierung).
    # Hinweis: Wird der Code von Alt-Ereignissen referenziert, lässt sich seine
    # Bezeichnung dort nicht mehr auflösen – zum Ausblenden im Dropdown ohne
    # Datenverlust stattdessen `active: false` setzen.
    def destroy
      codes = penalty_codes
      id = params[:id].to_s
      return render json: { error: 'Strafcode nicht gefunden' }, status: :not_found unless codes.key?(id)

      codes.delete(id)
      persist(codes)
      head :no_content
    end

    private

    def penalty_codes
      (Setting.current.penalty_codes || {}).deep_dup
    end

    # JSONB wird nur als geändert erkannt, wenn das Attribut neu zugewiesen wird –
    # In-Place-Mutation des Hash persistiert nicht zuverlässig.
    def persist(codes)
      setting = Setting.current
      setting.penalty_codes = codes
      setting.save!
    end

    def next_id(codes)
      ((codes.keys.map(&:to_i).max || 0) + 1).to_s
    end

    def validation_error(code, description, ignore_id: nil)
      return 'Der Strafcode muss aus genau 3 Ziffern bestehen (z. B. 902).' unless code.to_s.match?(/\A\d{3}\z/)
      return 'Eine Bezeichnung ist erforderlich.' if description.blank?

      duplicate = penalty_codes.any? { |k, v| k != ignore_id && v['code'] == code }
      return "Der Strafcode #{code} existiert bereits." if duplicate

      nil
    end

    def serialize(codes)
      codes.map { |id, v| entry_json(id, v) }.sort_by { |e| e[:code].to_s }
    end

    # Robust gegen Legacy-/Fremdformate: ältere penalty_codes-Einträge tragen
    # teils nur {"name"=>...} ohne code/description/active. Solche Einträge dürfen
    # nicht gelöscht werden (historische penalty_code_id-Referenzen), die Liste
    # darf an ihnen aber auch nicht scheitern (sonst 500 + nil-Sortierfehler).
    def entry_json(id, entry)
      entry = {} unless entry.is_a?(Hash)
      {
        id: id,
        code: entry['code'].to_s,
        description: (entry['description'] || entry['name']).to_s,
        active: [true, 'true'].include?(entry['active'])
      }
    end

    def authorize_admin!
      return if current_user&.permission_hash&.dig(:admin).present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
