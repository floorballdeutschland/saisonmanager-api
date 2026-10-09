# Schiri-Portal: Kursangebote sehen, sich selbst an- und abmelden. Die
# Personendaten kommen aus dem eigenen Schiri-Datensatz, nicht aus dem Request.
class RefereeCoursesPortalController < ApplicationController
  include RefereeCourseOffers

  before_action :require_referee!
  before_action :set_course, only: %i[register update_registration cancel]

  # GET /api/v2/referee/courses
  def index
    courses, levels = course_offers
    mine = @referee.referee_course_registrations.includes(:referee_course, :club).order(created_at: :desc)
    by_course = mine.reject(&:cancelled?).index_by(&:referee_course_id)
    render json: {
      own_state_association_id: @referee.club&.state_association_id,
      courses: courses.map do |c|
        c.offer_hash(levels_by_id: levels).merge(my_registration_id: by_course[c.id]&.id)
      end,
      registrations: mine.map { |r| own_registration_json(r) }
    }
  end

  # POST /api/v2/referee/courses/:id/registration
  def register
    if @referee.geburtsdatum.nil?
      return error_json('Bei deinem Schiedsrichterprofil fehlt das Geburtsdatum. ' \
                        'Bitte melde es über „Korrektur beantragen“ im Profil oder an die RSK.')
    end

    attrs = {
      referee: @referee, user: current_user, identity_match: 'account',
      vorname: @referee.vorname, nachname: @referee.nachname, geburtsdatum: @referee.geburtsdatum,
      email: current_user.email.presence || @referee.email, telefon: @referee.telefonnummer,
      club_id: @referee.club_id, stated_lizenznummer: @referee.lizenznummer&.to_s,
      desired_license_level_id: params.dig(:registration, :desired_license_level_id),
      remarks: params.dig(:registration, :remarks), custom_answers: answers_param || {}
    }
    result = RefereeCourseRegistrar.new(@course).register(attrs, source: 'portal', registered_by: current_user)
    return error_json(result.error) unless result.success?

    render json: own_registration_json(result.registration), status: :created
  end

  # PATCH /api/v2/referee/courses/:id/registration
  # Angestrebte Stufe, Bemerkung und Antworten, bis zum Anmeldeschluss.
  def update_registration
    registration = own_registration
    return error_json('Keine Anmeldung zu diesem Kurs', :not_found) if registration.nil?
    return error_json('Der Anmeldeschluss ist vorbei') if
      @course.registration_deadline && Time.current > @course.registration_deadline

    registration.assign_attributes(params.require(:registration).permit(:desired_license_level_id, :remarks))
    registration.custom_answers = answers_param if answers_param
    return error_json(registration.errors.full_messages.to_sentence) unless registration.save

    render json: own_registration_json(registration)
  end

  # DELETE /api/v2/referee/courses/:id/registration
  def cancel
    registration = own_registration
    return error_json('Keine Anmeldung zu diesem Kurs', :not_found) if registration.nil?

    result = RefereeCourseRegistrar.new(@course).cancel(registration)
    return error_json(result.error) unless result.success?

    render json: own_registration_json(registration)
  end

  private

  def require_referee!
    @referee = current_user&.referee
    return error_json('Kein Schiedsrichterprofil verknüpft', :forbidden) if @referee.nil?

    error_json('Nicht verfügbar', :forbidden) unless Setting.referee_courses_enabled?
  end

  def set_course
    @course = RefereeCourse.upcoming_offers.find_by(id: params[:id])
    error_json('Kurs nicht gefunden', :not_found) unless @course&.process_enabled?
  end

  def own_registration
    @course.registrations.where(referee_id: @referee.id).where.not(status: RefereeCourseRegistration::CANCELLED_STATUSES)
           .first
  end
end
