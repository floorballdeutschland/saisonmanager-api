module Admin
  # Lizenzvergabe durch FD fuer Kurse im System. Die Lizenz legt immer FD fest
  # (Entscheidung 09.10.2026); der LV reicht nur die Ergebnisse ein
  # (RefereeCourseSubmission). Hier pruefen Admin und FD-RSK jede bestandene
  # Teilnahme: Zuordnung zum Bestandsschiri, Lizenzstufe, dann erteilen oder mit
  # Begruendung ablehnen.
  #
  # Erteilen laeuft ueber den RefereeCourseResultApplier wie beim CSV-Import
  # (Neuanlage mit Lizenznummer, Lizenzfelder, Lizenzmail). Neue Schiris mit
  # E-Mail bekommen danach ein Konto (RefereeAccountCreator).
  class RefereeCourseLicensingController < ApplicationController
    before_action :authorize_fd!
    before_action :set_result, only: %i[update approve reject]

    # GET /api/v2/admin/referee_course_licensing?status=pending|done
    def index
      scope = RefereeCourseResult.where.not(referee_course_id: nil)
      scope = if params[:status] == 'done'
                scope.where(status: %w[applied rejected]).where(reviewed_at: 60.days.ago..)
              else
                scope.awaiting_fd_licensing
              end
      results = scope.includes(:referee, :referee_course_registration, referee_course: :state_association)
                     .order(:referee_course_id, :csv_nachname, :csv_vorname)
      levels = RefereeLicenseLevel.all.index_by(&:id)
      clubs = Club.where(id: results.map(&:master_club_id_final).compact).index_by(&:id)
      render json: results.map { |r| row_json(r, levels, clubs) }
    end

    # PATCH /api/v2/admin/referee_course_licensing/:id
    # Lizenzstufe festlegen oder die Zuordnung aendern (referee_id; leer heisst
    # neue Person).
    def update
      return locked_response unless @result.status == 'pending_review'

      attrs = params.require(:licensing)
      if attrs.key?(:lizenzstufe)
        level = attrs[:lizenzstufe].presence
        return error('Unbekannte Lizenzstufe') if level && !RefereeLicenseLevel.exists?(name: level, active: true)

        @result.lizenzstufe = level
        @result.gueltigkeit = level && RefereeLicenseLevel.gueltigkeit_for(level, @result.kursstichtag)
      end
      reassign(attrs[:referee_id]) if attrs.key?(:referee_id)
      return if performed?

      @result.save!
      render json: row_json(@result.reload)
    end

    # POST /api/v2/admin/referee_course_licensing/:id/approve
    def approve
      return locked_response unless @result.status == 'pending_review'

      outcome = grant(@result)
      return error(outcome) if outcome.is_a?(String)

      render json: row_json(@result.reload).merge(outcome)
    end

    # POST /api/v2/admin/referee_course_licensing/approve_many
    # Sammelfreigabe: alle uebergebenen Zeilen, die eine Lizenzstufe tragen.
    # Jede Zeile fuer sich, eine fehlerhafte haelt die anderen nicht auf.
    def approve_many
      ids = Array(params[:ids]).map(&:to_i)
      results = RefereeCourseResult.awaiting_fd_licensing.where(id: ids).to_a
      report = results.map do |result|
        outcome = grant(result)
        outcome.is_a?(String) ? { id: result.id, error: outcome } : { id: result.id, ok: true }
      end
      render json: { results: report }
    end

    # POST /api/v2/admin/referee_course_licensing/:id/reject
    def reject
      return locked_response unless @result.status == 'pending_review'

      reason = params[:rejection_reason].to_s.strip
      return error('Bitte einen Grund angeben') if reason.blank?

      @result.update!(status: 'rejected', rejection_reason: reason, reviewed_by_user: current_user,
                      reviewed_at: Time.current)
      render json: row_json(@result.reload)
    end

    private

    def authorize_fd!
      ph = current_user&.permission_hash || {}
      allowed = ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
      render json: { error: 'Nicht berechtigt' }, status: :forbidden unless allowed
    end

    def set_result
      @result = RefereeCourseResult.where.not(referee_course_id: nil).find_by(id: params[:id])
      render json: { error: 'Ergebnis nicht gefunden' }, status: :not_found if @result.nil?
    end

    def error(message)
      render json: { error: message }, status: :unprocessable_entity
    end

    def locked_response
      error('Diese Zeile ist bereits entschieden')
    end

    # Zuordnung aendern: anderer Bestandsschiri oder (leer) neue Person. Die
    # finalen Stammdaten folgen der Zuordnung, siehe RefereeCourseSubmission.
    def reassign(referee_id)
      registration = @result.referee_course_registration
      if referee_id.present?
        referee = Referee.where(merged_into_id: nil).find_by(id: referee_id)
        return error('Schiedsrichter nicht gefunden') if referee.nil?

        @result.assign_attributes(
          referee: referee, match_type: 'exact_match', match_field_count: 6,
          master_lizenznummer_final: referee.lizenznummer, master_vorname_final: referee.vorname,
          master_nachname_final: referee.nachname, master_geburtsdatum_final: referee.geburtsdatum,
          master_email_final: referee.email, master_club_id_final: referee.club_id
        )
      else
        @result.assign_attributes(
          referee: nil, match_type: 'new_entry', match_field_count: 0,
          master_lizenznummer_final: nil, master_vorname_final: registration&.vorname || @result.csv_vorname,
          master_nachname_final: registration&.nachname || @result.csv_nachname,
          master_geburtsdatum_final: registration&.geburtsdatum || @result.csv_geburtsdatum,
          master_email_final: registration&.email || @result.csv_email,
          master_club_id_final: registration&.club_id
        )
      end
    end

    # Erteilt die Lizenz. Rueckgabe: Fehlertext oder Hash mit Mail-/Kontostatus.
    def grant(result)
      return 'Bitte zuerst eine Lizenzstufe wählen' if result.lizenzstufe.blank?

      result.gueltigkeit ||= RefereeLicenseLevel.gueltigkeit_for(result.lizenzstufe, result.kursstichtag)
      applier = RefereeCourseResultApplier.new(result, performed_by_user: current_user)
      RefereeCourseResult.transaction do
        result.lock!
        return 'Diese Zeile ist bereits entschieden' unless result.status == 'pending_review'

        applier.call(review_required: false)
        sync_registration(result)
      end
      notification = applier.deliver_pending_license_notification
      { license_mail: notification.to_s, account: create_account(result.referee) }
    rescue RefereeCourseResultApplier::Error, ActiveRecord::RecordInvalid => e
      e.message
    end

    def sync_registration(result)
      registration = result.referee_course_registration
      return if registration.nil?

      level_id = RefereeLicenseLevel.where(name: result.lizenzstufe).pick(:id)
      registration.skip_required_answers = true
      registration.update!(referee_id: result.referee_id, awarded_license_level_id: level_id,
                           identity_match: registration.identity_match == 'account' ? 'account' : 'confirmed_existing')
    end

    # Neue Schiris mit Adresse bekommen gleich ein Konto. Ein Fehlschlag nimmt
    # die Lizenz nicht zurueck; das Konto laesst sich in der Schiri-Maske anlegen.
    def create_account(referee)
      return 'exists' if referee.nil? || referee.user
      return 'no_email' if referee.email.blank?

      RefereeAccountCreator.new(referee, deliver_later: true).call.success? ? 'created' : 'failed'
    rescue StandardError => e
      Rails.logger.warn("Kontoanlage nach Lizenzvergabe fuer Referee #{referee&.id} fehlgeschlagen: #{e.message}")
      'failed'
    end

    def row_json(result, levels = nil, clubs = nil)
      registration = result.referee_course_registration
      course = result.referee_course
      referee = result.referee
      levels ||= RefereeLicenseLevel.all.index_by(&:id)
      club_id = result.master_club_id_final
      club = clubs ? clubs[club_id] : Club.find_by(id: club_id)
      {
        id: result.id,
        status: result.status,
        lizenzstufe: result.lizenzstufe,
        gueltigkeit: result.gueltigkeit,
        rejection_reason: result.rejection_reason,
        reviewed_at: result.reviewed_at,
        new_referee_created: result.new_referee_created,
        course: {
          id: course.id, title: course.title, course_type: course.course_type, ends_on: course.ends_on,
          state_association: course.state_association&.name,
          license_levels: course.license_level_ids.filter_map { |id| levels[id]&.name }
        },
        person: {
          vorname: result.master_vorname_final, nachname: result.master_nachname_final,
          geburtsdatum: result.master_geburtsdatum_final, email: result.master_email_final,
          club: club&.name
        },
        referee: referee && {
          id: referee.id, lizenznummer: referee.lizenznummer, lizenzstufe: referee.lizenzstufe,
          gueltigkeit: referee.gueltigkeit, career_ended: referee.career_ended?
        },
        registration: registration && {
          id: registration.id, identity_match: registration.identity_match,
          match_candidates: registration.match_candidates,
          desired_level: levels[registration.desired_license_level_id]&.name,
          test_version: registration.test_version, points: registration.points&.to_f,
          stated_lizenznummer: registration.stated_lizenznummer, source: registration.source
        }
      }
    end
  end
end
