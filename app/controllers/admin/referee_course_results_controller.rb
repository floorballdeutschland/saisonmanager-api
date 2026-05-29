module Admin
  class RefereeCourseResultsController < ApplicationController
    before_action :set_result, only: %i[update approve reject]

    # GET /api/v2/admin/referee_course_results
    # Liste aller offenen Ergebnisse, gefiltert nach Rolle:
    #   - Admin / RSK FD (Scope 0): alle pending_review
    #   - RSK eines LV: nur pending_review in seinen Landesverbänden
    def index
      ph = current_user.permission_hash
      scope = RefereeCourseResult.pending_review
                                 .includes(:referee, :referee_course_import, :state_association)

      sa_ids = reviewer_state_association_ids(ph)
      return forbidden_response if sa_ids.nil?

      scope = scope.for_state_associations(sa_ids) unless sa_ids == :all
      render json: scope.order(:created_at).map { |r| short_result_hash(r) }
    end

    # PATCH /api/v2/admin/referee_course_results/:id
    # Der Importeur bearbeitet vor Submit die Master-Werte, die Lizenzstufe
    # + Gültigkeit und/oder den Match-Pointer (falls der Auto-Match daneben
    # liegt — z.B. bei Namensvettern). Nach Submit ist diese Route gesperrt.
    def update
      return forbidden_response unless importer_can_edit?(@result)

      attrs = update_params

      if attrs.key?(:referee_id)
        new_id = attrs[:referee_id].presence
        new_id = Integer(new_id, 10) if new_id.is_a?(String) && new_id.match?(/\A\d+\z/)
        @result.referee_id = new_id
      end

      apply_importer_master_fields(@result, attrs[:master_by_importer])
      sync_final_with_importer(@result)
      sync_state_association(@result)

      @result.lizenzstufe = attrs[:lizenzstufe] if attrs.key?(:lizenzstufe)
      @result.gueltigkeit = parse_date(attrs[:gueltigkeit]) if attrs.key?(:gueltigkeit)
      @result.match_field_count = recompute_match_field_count(@result)
      @result.match_type = recompute_match_type(@result)

      @result.save!
      render json: @result.short_hash
    end

    # POST /api/v2/admin/referee_course_results/:id/reject
    # Der LV-Reviewer weist den Datensatz zurueck. Wenn der Submit-Schritt zuvor
    # einen neuen Referee angelegt hat (`new_referee_created`), wird dieser
    # Datensatz mitgeloescht, sofern er noch keine anderen Course-Results oder
    # Spielverbindungen hat. Sonst sammeln sich Orphan-Referees an, die der LV
    # nicht freigegeben hat.
    def reject
      return forbidden_response unless reviewer_can_approve?(@result)
      return render(json: { error: 'Nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @result.status == 'pending_review'

      reason = params[:reason].to_s
      return render(json: { error: 'Begründung erforderlich' }, status: :unprocessable_entity) if reason.blank?

      ActiveRecord::Base.transaction do
        orphan_referee = orphan_referee_for(@result)
        @result.status = 'rejected'
        @result.reviewed_by_user = current_user
        @result.reviewed_at = Time.current
        @result.rejection_reason = reason
        @result.referee = nil if orphan_referee
        @result.save!

        orphan_referee&.destroy!
      end

      render json: @result.reload.short_hash
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /api/v2/admin/referee_course_results/:id/approve
    # Der LV-Reviewer gibt frei; optional kann er die Stammdaten zuvor
    # über `master_final` ändern. Lizenzstufe und Gültigkeit sind unveränderbar.
    def approve
      return forbidden_response unless reviewer_can_approve?(@result)
      return render(json: { error: 'Nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @result.status == 'pending_review'

      apply_final_master_fields(@result, params[:master_final] || {})
      sync_state_association(@result)

      RefereeCourseResultApplier.new(@result, performed_by_user: current_user)
                                .call(review_required: false)
      render json: @result.reload.short_hash
    rescue RefereeCourseResultApplier::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def set_result
      @result = RefereeCourseResult.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Datensatz nicht gefunden' }, status: :not_found
    end

    def forbidden_response
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Liefert die State-Association-IDs, deren Vorgänge der Benutzer reviewen
    # darf. `:all` heißt globaler Scope (Admin oder RSK FD).
    def reviewer_state_association_ids(perm_hash)
      return :all if perm_hash[:admin].present?
      return :all if perm_hash[:rsk].present? && perm_hash[:rsk].include?(0)
      return nil unless perm_hash[:rsk].present?

      go_ids = perm_hash[:rsk].reject(&:zero?)
      GameOperation.where(id: go_ids).pluck(:state_association_id).compact.uniq
    end

    def importer_can_edit?(result)
      return false unless result.referee_course_import.status == 'in_review'

      ph = current_user.permission_hash
      ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    end

    def reviewer_can_approve?(result)
      ph = current_user.permission_hash
      sa_ids = reviewer_state_association_ids(ph)
      return false if sa_ids.nil?
      return true  if sa_ids == :all

      sa_ids.include?(result.state_association_id)
    end

    def update_params
      params.permit(:lizenzstufe, :gueltigkeit, :referee_id, master_by_importer: {}).to_h.symbolize_keys
    end

    def apply_importer_master_fields(result, fields)
      return if fields.blank?

      result.master_lizenznummer_by_importer = to_integer(fields['lizenznummer']) if fields.key?('lizenznummer')
      result.master_vorname_by_importer      = fields['vorname']     if fields.key?('vorname')
      result.master_nachname_by_importer     = fields['nachname']    if fields.key?('nachname')
      result.master_geburtsdatum_by_importer = parse_date(fields['geburtsdatum']) if fields.key?('geburtsdatum')
      result.master_club_id_by_importer      = to_integer(fields['club_id']) if fields.key?('club_id')
      result.master_email_by_importer        = fields['email'] if fields.key?('email')
    end

    def apply_final_master_fields(result, fields)
      return if fields.blank?

      result.master_lizenznummer_final = to_integer(fields['lizenznummer']) if fields.key?('lizenznummer')
      result.master_vorname_final      = fields['vorname']     if fields.key?('vorname')
      result.master_nachname_final     = fields['nachname']    if fields.key?('nachname')
      result.master_geburtsdatum_final = parse_date(fields['geburtsdatum']) if fields.key?('geburtsdatum')
      result.master_club_id_final      = to_integer(fields['club_id']) if fields.key?('club_id')
      result.master_email_final        = fields['email'] if fields.key?('email')
    end

    # Vor Submit spiegeln die finalen Werte 1:1 die Importer-Werte wider —
    # der LV überschreibt sie ggf. einzeln beim Approve.
    def sync_final_with_importer(result)
      RefereeCourseResult::MASTER_FIELDS.each do |field|
        result["master_#{field}_final"] = result["master_#{field}_by_importer"]
      end
    end

    # Ein Referee gilt als Orphan, wenn er bei genau diesem Result als
    # Neuanlage erzeugt wurde und keine anderen Faelle daran haengen (weitere
    # Results, Game-Verbindungen, Wallet-Pass-Anlage). Sonst muss er bestehen
    # bleiben, damit nicht versehentlich produktive Daten verschwinden.
    def orphan_referee_for(result)
      return nil unless result.new_referee_created
      return nil unless result.referee

      referee = result.referee
      return nil if RefereeCourseResult.where(referee_id: referee.id).where.not(id: result.id).exists?
      return nil if referee.wallet_pass_issued_at.present?
      return nil if referee.games.exists?

      referee
    end

    def sync_state_association(result)
      club = Club.find_by(id: result.master_club_id_by_importer)
      result.state_association_id = club&.state_association_id
    end

    def recompute_match_field_count(result)
      return 0 unless result.referee

      csv_attrs = {
        lizenznummer: result.csv_lizenznummer,
        vorname:      result.csv_vorname,
        nachname:     result.csv_nachname,
        geburtsdatum: result.csv_geburtsdatum,
        email:        result.csv_email,
        verein:       result.csv_verein
      }
      # Identische Semantik wie beim initialen Import (siehe
      # RefereeCourseResult.count_csv_to_referee_matches): Vereinsabgleich ueber
      # exakten Namens-Lookup gegen Club.name, damit das Score-Ergebnis nicht
      # davon abhaengt, ob es beim Import oder beim Edit berechnet wurde.
      RefereeCourseResult.count_csv_to_referee_matches(
        csv_attrs, result.referee,
        club_lookup: ->(name) { Club.where('LOWER(name) = LOWER(?)', name.to_s.strip).first }
      )
    end

    def recompute_match_type(result)
      return 'new_entry'     if result.referee.nil?
      return 'exact_match'   if result.match_field_count == 6

      'partial_match'
    end

    def short_result_hash(result)
      base = result.short_hash
      base[:referee_snapshot] = {
        id: result.referee&.id,
        vorname: result.referee&.vorname,
        nachname: result.referee&.nachname,
        lizenznummer: result.referee&.lizenznummer,
        club_id: result.referee&.club_id
      }
      base[:state_association] = if result.state_association
                                   { id: result.state_association.id,
                                     name: result.state_association.name }
                                 end
      base
    end

    def to_integer(value)
      Integer(value.to_s.strip, 10) if value.to_s.strip.match?(/\A\d+\z/)
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      begin
        Date.strptime(value.to_s, '%d.%m.%Y')
      rescue ArgumentError
        nil
      end
    end
  end
end
