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
      unless @import.status == 'in_review'
        # Ein teilweise eingereichter Import ist NICHT abgeschlossen, aber auch
        # nicht mehr abbrechbar: Ein Teil seiner Zeilen ist angewendet.
        message = if @import.status == 'partially_submitted'
                    'Teilweise eingereichte Importe können nicht abgebrochen werden'
                  else
                    'Import bereits abgeschlossen'
                  end
        return render(json: { error: message }, status: :unprocessable_entity)
      end

      @import.update!(status: 'cancelled')
      head :no_content
    end

    # POST /api/v2/admin/referee_course_imports/:id/submit
    # Importeur reicht die einreichbaren Zeilen ein -- alle ausser den von ihm
    # zurueckgestellten. Jede davon wird je nach LV-Setting
    # (referee_license_review_enabled) und Match-Typ entweder direkt auf den
    # Referee angewendet (`applied`) oder bleibt für die LV-Kontrolle stehen
    # (`pending_review`).
    #
    # Bleiben zurueckgestellte Zeilen uebrig, endet der Import auf
    # `partially_submitted` und kann nach deren Klaerung erneut eingereicht
    # werden. Der Scope `submittable` haelt den zweiten Lauf von den Zeilen des
    # ersten fern.
    def submit
      return render(json: { error: 'Import nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @import.editable?

      if @import.referee_course_results.submittable.none?
        return render(json: { error: nothing_to_submit_error }, status: :unprocessable_entity)
      end

      validation_error = preflight_validation_error(@import.referee_course_results.submittable)
      return render(json: { error: validation_error }, status: :unprocessable_entity) if validation_error

      RefereeCourseResultApplier.reset_license_level_positions_cache!

      already_submitted = false
      appliers = []
      ActiveRecord::Base.transaction do
        @import.lock!
        rows = @import.referee_course_results.submittable.order(:id).to_a
        if !@import.editable? || rows.empty?
          # Zweiter paralleler Submit hat uns ueberholt.
          already_submitted = true
          raise ActiveRecord::Rollback
        end

        rows.each_with_index do |result, idx|
          target_state_association = StateAssociation.find_by(id: result.state_association_id)
          review_required = RefereeCourseSubmitPolicy.review_required?(result, target_state_association)

          begin
            applier = RefereeCourseResultApplier.new(result, performed_by_user: current_user)
            applier.call(review_required: review_required)
            # Nach dem Applier gesetzt und nicht vorher: Sein `save!` gehoert
            # ihm, dieses Merkmal dem Submit. Ab jetzt ist die Zeile aus der
            # Hand des Importeurs -- entweder angewendet oder in der
            # Warteschlange des Landesverbands.
            result.update!(submitted_at: Time.current)
            appliers << applier
          rescue RefereeCourseResultApplier::Error => e
            raise SubmitRowError.new(idx + 1, result, e.message)
          end
        end
        # Nicht `submittable`, sondern `open_for_importer`: Die zurueckgestellten
        # Zeilen sind gerade nicht einreichbar, halten den Import aber offen.
        @import.update!(
          status: @import.referee_course_results.open_for_importer.none? ? 'submitted' : 'partially_submitted'
        )
        # Das Verwerfen der letzten offenen Zeile sperrt den Import mit, damit
        # sich die beiden Wege nicht ueberholen -- siehe
        # RefereeCourseResultsController#discard.
      end

      if already_submitted
        return render(json: { error: 'Import wurde bereits eingereicht' }, status: :unprocessable_entity)
      end

      # Erst nach dem Commit, damit ein Fehler in einer späteren Zeile keine Mails
      # zu zurückgerollten Lizenzen hinterlässt. Zeilen, die auf das LV-Review
      # warten, sind hier still – ihre Mail geht beim Approve raus. Der Versand
      # selbst ist eingereiht (deliver_later), ein Kursimport mit vielen Zeilen
      # läuft dem Request also nicht davon.
      #
      # Nicht erreichbar und nichts zu melden getrennt zählen: Nach einem Kurs mit
      # vierzig Zeilen ist „28 ohne hinterlegte Adresse" eine Aufgabenliste,
      # „28 ohne Änderung" dagegen in Ordnung. Eine reine Gesamtzahl beantwortet
      # das nicht.
      outcomes = appliers.map(&:deliver_pending_license_notification)
      sent = outcomes.count(RefereeNotification::SENT)
      unreachable = outcomes.count(RefereeNotification::UNREACHABLE)
      Rails.logger.info("Kursimport #{@import.id}: #{sent} Lizenzmail(s) eingereiht, " \
                        "#{unreachable} ohne Adresse oder Gast, " \
                        "#{outcomes.count(RefereeNotification::FAILED)} fehlgeschlagen")

      render json: @import.reload.full_hash.merge(
        license_notifications: sent, license_notifications_unreachable: unreachable
      )
    rescue SubmitRowError => e
      render json: {
        error: e.message,
        row: e.row,
        result_id: e.result_id
      }, status: :unprocessable_entity
    end

    private

    # Zwei Lagen, die denselben leeren `submittable`-Scope erzeugen und dem
    # Importeur Verschiedenes sagen muessen. „Nichts mehr offen" heisst zudem:
    # Ein teilweise eingereichter Import ist fertig -- das zieht
    # `close_if_done!` hier nach, falls sich ein Verwerfen und ein Submit
    # ueberholt haben.
    def nothing_to_submit_error
      if @import.referee_course_results.open_for_importer.exists?
        'Keine einreichbaren Zeilen: alle offenen Zeilen sind zurückgestellt'
      else
        @import.close_if_done!
        'Keine offenen Zeilen mehr: alle Zeilen sind eingereicht oder verworfen'
      end
    end

    # Prueft nur die uebergebenen Zeilen: Eine zurueckgestellte Zeile ohne
    # Lizenzstufe darf die uebrigen nicht blockieren -- genau daran scheiterte
    # vorher die ganze Datei.
    def preflight_validation_error(results)
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
      # Getrennt vom Zielwert daneben: `matched_club` faellt auf den Verein des
      # Schiedsrichters zurueck, wenn der Name aus der Datei nichts trifft
      # (`matched_club&.id || referee&.club_id` im Import-Service). Wer die
      # Maske daran haengt, bekommt fuer genau den haeufigsten Fall faelschlich
      # Gleichheit gemeldet -- dieselbe Ursache wie in der Freigabe-Maske
      # (api#540). Der Wert traegt zusaetzlich die Herkunft des Treffers.
      csv_match = club_lookup.resolve(result.csv_verein) if result.csv_verein.present?
      base[:csv_club_match]      = csv_club_snapshot(csv_match)
      base[:csv_club_match_type] = csv_match&.last
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

    # Aus dem Bestand, den `club_lookup` fuer diese Anfrage ohnehin geladen hat:
    # ein `Club.find_by` je Zeile waren bei einem Import mit hundert Zeilen
    # hundert vermeidbare Abfragen.
    def club_snapshot(club_id)
      club = club_lookup.club_by_id(club_id)
      return nil unless club

      { id: club.id, name: club.name, state_association_id: club.state_association_id }
    end

    # Was der Vereinsname aus der Datei trifft, samt Herkunft des Treffers --
    # exakt, ueber den Langnamen, normalisiert oder aus der Alias-Liste. Ein
    # nicht-exakter Treffer ist eine Schlussfolgerung des Systems und gehoert
    # dem Importeur vor Augen, damit er sie pruefen kann. Die Herkunft ohne
    # Treffer (mehrdeutig, unbekannt, Platzhalter) traegt `csv_club_match_type`.
    def csv_club_snapshot(pair)
      club, match_type = pair
      return nil unless club

      { id: club.id, name: club.name, state_association_id: club.state_association_id,
        match_type: match_type }
    end

    # Ein Lookup je Request, nicht je Zeile (#show rendert den ganzen Import).
    def club_lookup
      @club_lookup ||= RefereeClubLookup.new
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
