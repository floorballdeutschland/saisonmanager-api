module Admin
  class RefereeCourseResultsController < ApplicationController
    before_action :set_result, only: %i[update approve reject]

    # GET /api/v2/admin/referee_course_results
    # Liste aller offenen Ergebnisse, gefiltert nach Rolle:
    #   - Admin / RSK FD (Scope 0): alle Zeilen auf `pending_review`
    #   - RSK eines LV: davon die seiner Landesverbände
    # „Offen" heißt hier zweierlei: Die Zeile steht auf `pending_review` UND ihr
    # Import ist eingereicht.
    #
    # `awaiting_lv_review` ist hier nicht optional: Ohne den Import-Status
    # standen auch die Vorschauzeilen eines noch nicht eingereichten und die
    # eines abgebrochenen Imports mit einem „Freigeben"-Knopf in dieser Liste.
    def index
      ph = current_user.permission_hash
      scope = RefereeCourseResult.pending_review
                                 .awaiting_lv_review
                                 .includes(:referee, :referee_course_import, :state_association)

      sa_ids = reviewer_state_association_ids(ph)
      return forbidden_response if sa_ids.nil?

      scope = scope.for_state_associations(sa_ids) unless sa_ids == :all
      results = scope.order(:created_at).to_a
      clubs = clubs_by_id_for(results)
      csv_clubs = csv_club_matches_for(results)
      render json: results.map { |r| short_result_hash(r, clubs, csv_clubs) }
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

      if attrs.key?(:lizenzstufe)
        @result.lizenzstufe = attrs[:lizenzstufe]
        # Gültigkeit aus der Dauer der Stufe ableiten, sofern nicht explizit
        # mitgesendet (manueller Wert hat Vorrang, siehe unten).
        unless attrs.key?(:gueltigkeit)
          derived = RefereeLicenseLevel.gueltigkeit_for(@result.lizenzstufe, @result.kursstichtag)
          @result.gueltigkeit = derived if derived
        end
      end
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
      return not_submitted_response unless @result.awaiting_lv_review?
      return render(json: { error: 'Nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @result.status == 'pending_review'

      reason = params[:reason].to_s
      return render(json: { error: 'Begründung erforderlich' }, status: :unprocessable_entity) if reason.blank?

      ActiveRecord::Base.transaction do
        orphan_referee = orphan_referee_for(@result)
        @result.status = 'rejected'
        # Eine zurückgewiesene Zeile löst keine Lizenzmail aus.
        @result.license_notification_pending = false
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
      return not_submitted_response unless @result.awaiting_lv_review?
      return render(json: { error: 'Nicht im Review-Status' }, status: :unprocessable_entity) \
        unless @result.status == 'pending_review'

      apply_final_master_fields(@result, params[:master_final] || {})
      sync_state_association(@result)

      applier = RefereeCourseResultApplier.new(@result, performed_by_user: current_user)
      begin
        applier.call(review_required: false)
      rescue RefereeCourseResultApplier::Error => e
        # Die Meldung des Appliers traegt Validierungstexte und die interne
        # Result-ID; fuer den Reviewer ist sie unbrauchbar. Der Vorgang gehoert
        # aber in die Diagnose, sonst ist spaeter nicht zu rekonstruieren,
        # welche Zeile warum nicht durchging.
        Rails.logger.error("Kursfreigabe Result ##{@result.id} fehlgeschlagen: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        return render(json: { error: 'Die Freigabe konnte nicht gespeichert werden' },
                      status: :unprocessable_entity)
      end

      # Nach dem Commit: Die Lizenzmail zu einer review-pflichtigen Zeile geht
      # erst hier raus, nicht schon beim Submit. Der Ausgang wird gemeldet und
      # nicht verworfen: „kein Empfaenger hinterlegt" ist eine Aufgabe fuer den
      # Reviewer, und als Erfolg gemeldet wuerde sie nie jemand bemerken.
      # Gleiche Begruendung wie beim Submit (RefereeCourseImportsController).
      outcome = applier.deliver_pending_license_notification
      Rails.logger.info("Kursfreigabe Result ##{@result.id}: Lizenzmail #{outcome}")
      render json: @result.reload.short_hash.merge(license_notification: outcome)
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

    # Zeilen eines nicht eingereichten oder abgebrochenen Imports sind keine
    # Freigabe-Faelle. Nach dem Filter in #index kann eine frisch geladene Liste
    # sie gar nicht mehr enthalten; erreichbar bleiben eine vor diesem Stand
    # geladene Maske, direkte API-Aufrufe und Statusaenderungen an der Datenbank
    # (auf Produktion vorgekommen). Der Guard ist also bewusst defensiv.
    def not_submitted_response
      render json: { error: 'Der Import ist nicht eingereicht. Die Liste wird neu geladen.' },
             status: :unprocessable_entity
    end

    # Liefert die State-Association-IDs, deren Vorgänge der Benutzer reviewen
    # darf. `:all` heißt globaler Scope (Admin oder RSK FD).
    def reviewer_state_association_ids(perm_hash)
      return :all if perm_hash[:admin].present?
      return :all if perm_hash[:rsk].present? && perm_hash[:rsk].include?(0)
      return nil unless perm_hash[:rsk].present?

      go_ids = perm_hash[:rsk].reject(&:zero?)
      # Ueber den Verbandsbaum und nicht ueber GameOperation#state_association_id:
      # In die Ergebniszeile schreibt #sync_state_association die rohe
      # `clubs.state_association_id`, also bei einem Spielverbund den
      # untergeordneten Landesverband. Die Spalte des Spielbetriebs traegt nur die
      # Wurzel, damit haette der RSK eines Verbunds seine eigenen
      # Kursergebnisse nie zu sehen bekommen. Gleiche Ursache wie in
      # RefereeScoping#lv_club_ids.
      Club.responsible_state_association_ids(go_ids)
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
    # Results, Game-Verbindungen). Sonst muss er bestehen
    # bleiben, damit nicht versehentlich produktive Daten verschwinden.
    def orphan_referee_for(result)
      return nil unless result.new_referee_created
      return nil unless result.referee

      referee = result.referee
      return nil if RefereeCourseResult.where(referee_id: referee.id).where.not(id: result.id).exists?
      return nil if referee.games.exists?

      referee
    end

    # Der finale Verein ist massgeblich, nicht der des Importeurs: Beim Freigeben
    # darf der LV den Verein aendern, und der Applier schreibt genau diesen Wert
    # auf den Schiedsrichter. Laege hier weiter der Importeurs-Verein, truege die
    # Zeile dauerhaft den Landesverband des unkorrigierten Vereins, und ueber
    # genau dieses Feld filtert `for_state_associations` spaeter.
    # Im `update`-Pfad sind beide Seiten gleich, dort spiegelt
    # `sync_final_with_importer` unmittelbar davor.
    def sync_state_association(result)
      club = Club.find_by(id: result.master_club_id_final)
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

    # Clubs der ganzen Liste in einer Abfrage: Sowohl der Verein des Schiris als
    # auch der gematchte Verein der Zeile werden je Zeile gebraucht, einzeln
    # geladen waeren das bis zu zwei Abfragen pro Zeile. Die Liste umfasst dabei
    # nicht einen Kurs, sondern alle offenen Zeilen aller eingereichten Importe
    # in den Landesverbaenden des Reviewers.
    def clubs_by_id_for(results)
      ids = results.flat_map { |r| [r.referee&.club_id, r.master_club_id_final] }.compact.uniq
      Club.where(id: ids).index_by(&:id)
    end

    # Vereinsnamen aus der Datei in einer Abfrage aufloesen, geschluesselt nach
    # der normalisierten Schreibweise. Der Lookup ist derselbe wie im
    # Import-Service und in `recompute_match_field_count` (exakter Name, nur
    # Gross-/Kleinschreibung und Randleerzeichen egal), damit die Anzeige nicht
    # anders urteilt als der gespeicherte Score.
    def csv_club_matches_for(results)
      names = results.filter_map { |r| r.csv_verein.presence&.strip }.uniq
      return {} if names.empty?

      Club.where('LOWER(name) IN (?)', names.map(&:downcase))
          .index_by { |club| club.name.strip.downcase }
    end

    def short_result_hash(result, clubs = {}, csv_clubs = {})
      base = result.short_hash
      referee = result.referee
      # Vollstaendiger Snapshot inklusive Geburtsdatum, E-Mail und Vereinsname:
      # Fehlt ein Feld hier, zeigt die Freigabe-Maske in der Spalte „Datenbank"
      # ein „—", obwohl der Wert beim Schiri steht. Eine Abweichung in genau
      # diesem Feld ist dann nicht zu sehen, und der Match-Score (zaehlt alle
      # sechs Merkmale) wird unerklaerlich.
      base[:referee_snapshot] = {
        id: referee&.id,
        vorname: referee&.vorname,
        nachname: referee&.nachname,
        lizenznummer: referee&.lizenznummer,
        geburtsdatum: referee&.geburtsdatum,
        email: referee&.email,
        club_id: referee&.club_id,
        club_name: clubs[referee&.club_id]&.name
      }
      # Der Verein, den die Freigabe schreiben wuerde. `csv.verein` traegt den
      # Namen aus der Datei, der hier gematchte Club den Stand der Datenbank --
      # beides braucht die Maske, um einen Vereins-Konflikt zu zeigen.
      base[:matched_club] = club_snapshot(clubs[result.master_club_id_final])
      # Der Verein, den der Name aus der Datei trifft, oder nichts. Bewusst
      # getrennt von `matched_club`: Das traegt `master_club_id_final`, und das
      # faellt beim Import auf den Verein des Schiedsrichters zurueck, wenn der
      # Name nicht trifft (`matched_club&.id || referee&.club_id` im
      # Import-Service). Wer damit die Abweichung berechnet, bekommt fuer den
      # haeufigsten Teilmatch ueberhaupt (ausgeschriebener Vereinsname in der
      # Datei gegen die Kurzform in der Datenbank) faelschlich Gleichheit.
      base[:csv_club_match] = club_snapshot(csv_clubs[result.csv_verein.presence&.strip&.downcase])
      base[:state_association] = if result.state_association
                                   { id: result.state_association.id,
                                     name: result.state_association.name }
                                 end
      base
    end

    def club_snapshot(club)
      return nil unless club

      { id: club.id, name: club.name, state_association_id: club.state_association_id }
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
