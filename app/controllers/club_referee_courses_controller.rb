# Vereinsansicht der Schiedsrichterkurse (Vereinsmanager): Angebote sehen,
# eigene Schiris oder neue Personen anmelden (Sammelanmeldung, wie bisher in
# BW und NRW ueblich) und die Anmeldungen des Vereins verfolgen.
#
# Angemeldet werden nur Personen mit einem der eigenen Vereine, und die
# Rechnung geht an diesen Verein. Unter 16 braucht eine neue Person die
# Einwilligung der Erziehungsberechtigten (RefereeCourseRegistrar).
class ClubRefereeCoursesController < ApplicationController
  include RefereeCourseOffers

  before_action :require_vm!
  before_action :set_course, only: %i[register]
  before_action :set_registration, only: %i[cancel]

  # GET /api/v2/club/referee_courses
  def index
    courses, levels = course_offers
    registrations = RefereeCourseRegistration.where(club_id: @club_ids).or(
      RefereeCourseRegistration.where(billing_club_id: @club_ids)
    ).joins(:referee_course).merge(RefereeCourse.where('ends_on IS NULL OR ends_on >= ?', 1.year.ago.to_date))
                                             .includes(:referee_course, :club).order(created_at: :desc)
    render json: {
      clubs: Club.where(id: @club_ids).order(:name).map { |c| { id: c.id, name: c.name } },
      courses: courses.map { |c| c.offer_hash(levels_by_id: levels) },
      registrations: registrations.map { |r| own_registration_json(r) }
    }
  end

  # GET /api/v2/club/referee_courses/referees
  # Schiris der eigenen Vereine zur Auswahl.
  def referees
    list = Referee.where(club_id: @club_ids, merged_into_id: nil).order(:nachname, :vorname)
    render json: list.map { |r|
      { id: r.id, vorname: r.vorname, nachname: r.nachname, lizenznummer: r.lizenznummer,
        lizenzstufe: r.lizenzstufe, club_id: r.club_id }
    }
  end

  # POST /api/v2/club/referee_courses/:id/registrations
  def register
    attrs = registration_attrs
    return if performed?

    result = RefereeCourseRegistrar.new(@course).register(attrs, source: 'club', registered_by: current_user)
    return error_json(result.error) unless result.success?

    render json: own_registration_json(result.registration), status: :created
  end

  # DELETE /api/v2/club/referee_courses/registrations/:registration_id
  def cancel
    result = RefereeCourseRegistrar.new(@registration.referee_course).cancel(@registration)
    return error_json(result.error) unless result.success?

    render json: own_registration_json(@registration)
  end

  private

  def require_vm!
    @club_ids = Array(current_user&.club_ids).map(&:to_i)
    return error_json('Nicht berechtigt', :forbidden) if @club_ids.empty?

    error_json('Nicht verfügbar', :forbidden) unless Setting.referee_courses_enabled?
  end

  def set_course
    @course = RefereeCourse.upcoming_offers.find_by(id: params[:id])
    error_json('Kurs nicht gefunden', :not_found) unless @course&.process_enabled?
  end

  def set_registration
    @registration = RefereeCourseRegistration.where(club_id: @club_ids).find_by(id: params[:registration_id])
    error_json('Anmeldung nicht gefunden', :not_found) if @registration.nil?
  end

  def registration_attrs
    p = params.require(:registration)
    common = {
      desired_license_level_id: p[:desired_license_level_id], remarks: p[:remarks],
      custom_answers: answers_param || {}
    }
    if p[:referee_id].present?
      referee = Referee.where(club_id: @club_ids, merged_into_id: nil).find_by(id: p[:referee_id])
      return error_json('Schiedsrichter gehört nicht zu Ihrem Verein', :not_found) if referee.nil?

      return common.merge(
        referee: referee, user_id: User.where(referee_id: referee.id).pick(:id), identity_match: 'confirmed_existing',
        vorname: referee.vorname, nachname: referee.nachname, geburtsdatum: referee.geburtsdatum,
        email: referee.email, club_id: referee.club_id, stated_lizenznummer: referee.lizenznummer&.to_s
      )
    end

    club_id = p[:club_id].presence&.to_i || (@club_ids.one? ? @club_ids.first : nil)
    return error_json('Bitte einen Ihrer Vereine wählen') unless @club_ids.include?(club_id)

    common.merge(
      identity_match: 'new_person', vorname: p[:vorname], nachname: p[:nachname], geburtsdatum: p[:geburtsdatum],
      email: p[:email], club_id: club_id, guardian_name: p[:guardian_name], guardian_email: p[:guardian_email]
    )
  end
end
