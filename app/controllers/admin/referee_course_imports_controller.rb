module Admin
  class RefereeCourseImportsController < ApplicationController
    before_action :authorize_importer!
    before_action :set_import, only: %i[show destroy submit]

    MAX_CSV_BYTES = 5 * 1024 * 1024
    ALLOWED_CSV_CONTENT_TYPES = %w[text/csv text/plain application/vnd.ms-excel application/csv].freeze

    SubmitRowError = Class.new(StandardError) do
      attr_reader :row, :result_id

      def initialize(row, result, message)
        @row = row
        @result_id = result.id
        identity = [result.csv_nachname, result.csv_vorname,
                    "Liz. #{result.csv_lizenznummer || '—'}"].compact.join(', ')
        super("Zeile #{row} (#{identity}): #{message}")
      end
    end

    # GET /api/v2/admin/referee_course_imports
    def index
      imports = RefereeCourseImport.includes(:uploaded_by_user)
                                   .order(created_at: :desc)
      imports = imports.where(uploaded_by_user_id: current_user.id) unless admin_user?
      render json: imports.map(&:full_hash)
    end

    # GET /api/v2/admin/referee_course_imports/:id
    def show
      results = @import.referee_course_results
                       .includes(:referee, :state_association)
                       .order(:id)
      render json: @import.full_hash.merge(results: results.map { |r| result_hash(r) })
    end

    # POST /api/v2/admin/referee_course_imports
    def create
      file = params[:file]
      return render(json: { error: 'CSV-Datei fehlt' }, status: :unprocessable_entity) if file.blank?

      if file.respond_to?(:size) && file.size > MAX_CSV_BYTES
        return render(json: { error: "Datei zu groß (max. #{MAX_CSV_BYTES / 1024 / 1024} MB)" },
                      status: :unprocessable_entity)
      end

      content_type = file.respond_to?(:content_type) ? file.content_type.to_s : ''
      if content_type.present? && ALLOWED_CSV_CONTENT_TYPES.exclude?(content_type)
        return render(json: { error: "Unzulässiger Datei-Typ (#{content_type}). Erwartet wird CSV." },
                      status: :unprocessable_entity)
      end

      content = file.respond_to?(:read) ? file.read : file.to_s
      original_filename = file.respond_to?(:original_filename) ? file.original_filename : 'upload.csv'
      service = RefereeCourseImportService.new(
        csv_content: content,
        filename: original_filename,
        uploaded_by_user: current_user
      )
      import = service.call

      if import.nil?
        return render(json: { error: service.errors.join(' ') }, status: :unprocessable_entity)
      end

      # Original-CSV als Audit-Trail an den Import attachen (Active Storage),
      # damit Rueckfragen nach Wochen/Monaten gegen die echte Quelle abgeglichen
      # werden koennen und nicht nur gegen die normalisierten csv_*-Felder.
      attach_source_csv(import, file, content, content_type, original_filename)

      render json: import.full_hash, status: :created
    end

    # DELETE /api/v2/admin/referee_course_imports/:id
    def destroy
      return render(json: { error: 'Import bereits abgeschlossen' }, status: :unprocessable_entity) \
        unless @import.status == 'in_review'

      @import.update!(status: 'cancelled')
      head :no_content
    end

    # POST /api/v2/admin/referee_course_imports/:id/submit
    # Importeur reicht den Import ein. Jede Ergebniszeile wird je nach
    # LV-Setting (referee_license_review_enabled) und Match-Typ entweder
    # direkt auf den Referee angewendet (`applied`) oder bleibt für die LV-
    # Kontrolle stehen (`pending_review`).
    def submit
      return render(json: { error: 'Import nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @import.status == 'in_review'

      validation_error = preflight_validation_error(@import)
      return render(json: { error: validation_error }, status: :unprocessable_entity) if validation_error

      RefereeCourseResultApplier.reset_license_level_positions_cache!

      already_submitted = false
      ActiveRecord::Base.transaction do
        @import.lock!
        unless @import.status == 'in_review'
          # Zweiter paralleler Submit hat uns ueberholt.
          already_submitted = true
          raise ActiveRecord::Rollback
        end

        @import.referee_course_results.order(:id).each_with_index do |result, idx|
          target_state_association = StateAssociation.find_by(id: result.state_association_id)
          review_required = RefereeCourseSubmitPolicy.review_required?(result, target_state_association)

          begin
            RefereeCourseResultApplier.new(result, performed_by_user: current_user)
                                      .call(review_required: review_required)
          rescue RefereeCourseResultApplier::Error => e
            raise SubmitRowError.new(idx + 1, result, e.message)
          end
        end
        @import.update!(status: 'submitted')
      end

      if already_submitted
        return render(json: { error: 'Import wurde bereits eingereicht' }, status: :unprocessable_entity)
      end

      render json: @import.reload.full_hash
    rescue SubmitRowError => e
      render json: {
        error: e.message,
        row: e.row,
        result_id: e.result_id
      }, status: :unprocessable_entity
    end

    private

    def preflight_validation_error(import)
      results = import.referee_course_results

      missing_stufe = results.where(lizenzstufe: [nil, '']).count
      return "Für #{missing_stufe} Datensätze fehlt die Lizenzstufe" if missing_stufe.positive?

      missing_gueltigkeit = results.where(gueltigkeit: nil).count
      if missing_gueltigkeit.positive?
        return "Für #{missing_gueltigkeit} Datensätze fehlt das Gültigkeitsdatum " \
               '(meist wegen unparsbarem Kurs-Datum in der CSV)'
      end

      known_levels = RefereeLicenseLevel.pluck(:name).to_set
      unknown = results.where.not(lizenzstufe: known_levels.to_a).pluck(:lizenzstufe).uniq
      return "Unbekannte Lizenzstufen: #{unknown.join(', ')}" if unknown.any?

      nil
    end

    def set_import
      @import = RefereeCourseImport.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Import nicht gefunden' }, status: :not_found
    end

    def authorize_importer!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:rsk].present? && ph[:rsk].include?(0)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def admin_user?
      ph = current_user.permission_hash
      ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    end

    def result_hash(result)
      base = result.short_hash
      base[:referee_snapshot] = referee_snapshot(result.referee) if result.referee
      base[:matched_club]     = club_snapshot(result.master_club_id_by_importer)
      base[:age_at_kursstichtag] = age_at(result.master_geburtsdatum_by_importer, result.kursstichtag)
      base[:previous_season_game_count] = previous_season_game_count(result.referee)
      base
    end

    def referee_snapshot(referee)
      {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        vorname: referee.vorname,
        nachname: referee.nachname,
        geburtsdatum: referee.geburtsdatum,
        email: referee.email,
        club_id: referee.club_id,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit
      }
    end

    def club_snapshot(club_id)
      club = Club.find_by(id: club_id)
      return nil unless club

      { id: club.id, name: club.name, state_association_id: club.state_association_id }
    end

    def age_at(birthdate, reference_date)
      return nil if birthdate.blank? || reference_date.blank?

      age = reference_date.year - birthdate.year
      age -= 1 if reference_date < birthdate + age.years
      age
    end

    def attach_source_csv(import, file, content, content_type, original_filename)
      io = file.respond_to?(:rewind) ? file.tap(&:rewind) : StringIO.new(content)
      import.source_csv.attach(
        io: io,
        filename: original_filename,
        content_type: content_type.presence || 'text/csv'
      )
    rescue StandardError => e
      # Audit-Attach ist Best-Effort: ein Active-Storage-Fehler soll den Import
      # nicht zurueckweisen (die normalisierten csv_*-Felder reichen fuer die
      # Funktionalitaet); aber sichtbar machen.
      Rails.logger.warn("Audit-CSV-Attach fehlgeschlagen für Import #{import.id}: #{e.class}: #{e.message}")
    end

    def previous_season_game_count(referee)
      return 0 unless referee&.lizenznummer

      prev = Setting.current_season_id.to_i - 1
      return 0 if prev <= 0

      referee.games(season_id: prev).count
    end
  end
end
