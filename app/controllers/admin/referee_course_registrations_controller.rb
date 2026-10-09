module Admin
  # Teilnehmerliste eines Kurses in der Verwaltung. In Paket 1 traegt die RSK
  # Teilnehmende von Hand ein (Bestandsschiri oder neue Person); die
  # Selbstanmeldung kommt mit dem Portal und der oeffentlichen Seite.
  class RefereeCourseRegistrationsController < ApplicationController
    include RefereeCourseAccess

    before_action :require_editable_course!, except: :index
    before_action :set_registration, only: %i[update destroy]

    PERSON = %i[vorname nachname geburtsdatum email telefon club_id billing_club_id billing_address
                remarks desired_license_level_id stated_lizenznummer guardian_name guardian_email].freeze
    MANAGED = %i[status result test_version points awarded_license_level_id].freeze
    # Zustaende, die die Verwaltung von Hand setzen darf. Die Bestaetigungs-
    # zustaende (pending_*) entstehen nur ueber die Selbstanmeldung.
    SETTABLE_STATUSES = %w[registered waitlisted attended no_show cancelled_by_organizer].freeze

    # GET /api/v2/admin/referee_courses/:referee_course_id/registrations
    def index
      registrations = @course.registrations
                             .includes(:club, :billing_club, :referee, :desired_license_level, :awarded_license_level)
                             .order(:created_at, :id)
      render json: registrations.map { |r| registration_json(r) }
    end

    # POST /api/v2/admin/referee_courses/:referee_course_id/registrations
    # Mit `referee_id` aus dem Bestand (Daten vom Schiri), sonst als neue
    # Person. Ist der Kurs voll, landet die Anmeldung auf der Warteliste, es
    # sei denn, `over_capacity` ist gesetzt (Ausnahme durch die RSK).
    def create
      registration = @course.registrations.new(
        registered_by_user: current_user, skip_required_answers: true, identity_match: 'new_person'
      )
      if params.dig(:registration, :referee_id).present?
        referee = Referee.where(merged_into_id: nil).find_by(id: params.dig(:registration, :referee_id))
        return render(json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found) if referee.nil?

        take_over_referee(registration, referee)
      end
      registration.assign_attributes(person_params)
      registration.custom_answers = answers_param if answers_param
      registration.status = initial_status

      return validation_error(registration) unless registration.save

      render json: registration_json(registration), status: :created
    end

    # PATCH /api/v2/admin/referee_courses/:referee_course_id/registrations/:id
    def update
      @registration.skip_required_answers = true
      @registration.assign_attributes(person_params.merge(managed_params))
      @registration.custom_answers = answers_param if answers_param
      if params.dig(:registration, :referee_id).present?
        referee = Referee.where(merged_into_id: nil).find_by(id: params.dig(:registration, :referee_id))
        return render(json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found) if referee.nil?

        @registration.referee = referee
        @registration.user_id = User.where(referee_id: referee.id).pick(:id)
        @registration.identity_match = 'confirmed_existing'
      end
      if @registration.status_changed?
        unless SETTABLE_STATUSES.include?(@registration.status)
          return render json: { error: 'Status nicht erlaubt' }, status: :unprocessable_entity
        end

        @registration.cancelled_at = @registration.cancelled? ? Time.current : nil
      end

      return validation_error(@registration) unless @registration.save

      render json: registration_json(@registration)
    end

    # DELETE /api/v2/admin/referee_courses/:referee_course_id/registrations/:id
    # Absage durch die Veranstalter. Die Zeile bleibt fuer die Nachvollziehbarkeit.
    # Ohne Validierung: Eine Absage darf nicht an Angaben scheitern, die erst
    # nachtraeglich ungueltig wurden (etwa eine aus dem Kurs entfernte Stufe).
    def destroy
      @registration.update_columns(status: 'cancelled_by_organizer', cancelled_at: Time.current,
                                   updated_at: Time.current)
      head :no_content
    end

    private

    def set_registration
      @registration = @course.registrations.find_by(id: params[:id])
      render json: { error: 'Anmeldung nicht gefunden' }, status: :not_found if @registration.nil?
    end

    def person_params
      params.require(:registration).permit(*PERSON).to_h
    end

    def managed_params
      params.require(:registration).permit(*MANAGED).to_h
    end

    def answers_param
      raw = params.dig(:registration, :custom_answers)
      return nil if raw.nil?

      raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
    end

    def initial_status
      return 'waitlisted' if params.dig(:registration, :status) == 'waitlisted'
      return 'registered' if ActiveModel::Type::Boolean.new.cast(params.dig(:registration, :over_capacity))
      return 'waitlisted' if @course.max_participants && @course.free_seats.zero?

      'registered'
    end

    def take_over_referee(registration, referee)
      registration.referee = referee
      registration.user_id = User.where(referee_id: referee.id).pick(:id)
      registration.identity_match = 'confirmed_existing'
      registration.vorname = referee.vorname
      registration.nachname = referee.nachname
      registration.geburtsdatum = referee.geburtsdatum
      registration.email = referee.email
      registration.club_id = referee.club_id
      registration.stated_lizenznummer = referee.lizenznummer&.to_s
    end

    def registration_json(registration)
      {
        id: registration.id,
        referee_id: registration.referee_id,
        lizenznummer: registration.referee&.lizenznummer,
        current_license_level: registration.referee&.lizenzstufe,
        user_id: registration.user_id,
        vorname: registration.vorname,
        nachname: registration.nachname,
        geburtsdatum: registration.geburtsdatum,
        age_at_course: registration.age_at_course,
        email: registration.email,
        telefon: registration.telefon,
        club: registration.club && { id: registration.club.id, name: registration.club.name },
        billing_club: registration.billing_club && { id: registration.billing_club.id,
                                                     name: registration.billing_club.name },
        billing_address: registration.billing_address,
        remarks: registration.remarks,
        desired_license_level_id: registration.desired_license_level_id,
        awarded_license_level_id: registration.awarded_license_level_id,
        stated_lizenznummer: registration.stated_lizenznummer,
        guardian_name: registration.guardian_name,
        guardian_email: registration.guardian_email,
        guardian_confirmed_at: registration.guardian_confirmed_at,
        status: registration.status,
        cancelled_at: registration.cancelled_at,
        late_cancellation: registration.late_cancellation?,
        result: registration.result,
        test_version: registration.test_version,
        points: registration.points&.to_f,
        identity_match: registration.identity_match,
        match_candidates: registration.match_candidates,
        custom_answers: registration.custom_answers,
        fee_cents: registration.fee_cents,
        created_at: registration.created_at
      }
    end
  end
end
