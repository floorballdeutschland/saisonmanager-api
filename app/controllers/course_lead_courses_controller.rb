# „Meine Kurse" fuer die Kursleitung (User::COURSE_LEAD_ROLE_ID): nur die Kurse,
# denen das Konto zugeordnet ist, und davon nur, was fuer die Durchfuehrung
# noetig ist. Keine Kontaktdaten und keine Rechnungsangaben der Teilnehmenden,
# Zusatzfelder nur mit `visible_to_lead`.
#
# Schreiben darf die Kursleitung Anwesenheit und Testergebnis, solange der Kurs
# nicht abgeschlossen ist. Eingereicht wird von der RSK.
class CourseLeadCoursesController < ApplicationController
  before_action :set_course, only: %i[show update_registration]

  LEAD_STATUSES = %w[registered attended no_show].freeze

  # GET /api/v2/course_lead/courses
  def index
    courses = RefereeCourse.joins(:leads).where(referee_course_leads: { user_id: current_user.id })
                           .includes(:state_association).ordered.to_a.select(&:process_enabled?)
    render json: courses.map { |c| c.summary_hash.merge(taken_seats: c.taken_seats) }
  end

  # GET /api/v2/course_lead/courses/:id
  def show
    fields = @course.fields.active.where(visible_to_lead: true)
    registrations = @course.registrations.where(status: RefereeCourseRegistration::SEAT_STATUSES + ['waitlisted'])
                           .includes(:club, :referee).order(:nachname, :vorname)
    render json: @course.summary_hash.merge(
      sessions: @course.sessions,
      online_platform: @course.online_platform,
      description: @course.description,
      editable: @course.editable?,
      fields: fields.map(&:definition_hash),
      registrations: registrations.map { |r| registration_json(r, fields) }
    )
  end

  # PATCH /api/v2/course_lead/courses/:id/registrations/:registration_id
  def update_registration
    unless @course.editable?
      return render json: { error: 'Der Kurs ist abgeschlossen' }, status: :unprocessable_entity
    end

    registration = @course.registrations.find_by(id: params[:registration_id])
    return render json: { error: 'Anmeldung nicht gefunden' }, status: :not_found if registration.nil?

    attrs = params.require(:registration).permit(:status, :result, :test_version, :points).to_h
    if attrs.key?('status') && LEAD_STATUSES.exclude?(attrs['status'])
      return render json: { error: 'Status nicht erlaubt' }, status: :unprocessable_entity
    end
    # Nur Anmeldungen mit Platz: wartende (Warteliste, E-Mail- oder
    # Eltern-Bestaetigung offen) darf die Kursleitung nicht umstellen, sonst
    # liesse sich die Einwilligung umgehen und ein voller Kurs ueberbuchen.
    unless RefereeCourseRegistration::SEAT_STATUSES.include?(registration.status)
      return render json: { error: 'Diese Anmeldung hält keinen Platz' }, status: :unprocessable_entity
    end

    registration.skip_required_answers = true
    unless registration.update(attrs)
      return render json: { error: registration.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    render json: registration_json(registration, @course.fields.active.where(visible_to_lead: true))
  end

  private

  def set_course
    @course = RefereeCourse.joins(:leads).where(referee_course_leads: { user_id: current_user.id })
                           .find_by(id: params[:id])
    return if @course&.process_enabled?

    render json: { error: 'Kurs nicht gefunden' }, status: :not_found
  end

  def registration_json(registration, fields)
    keys = fields.map { |f| f.id.to_s }
    {
      id: registration.id,
      vorname: registration.vorname,
      nachname: registration.nachname,
      age_at_course: registration.age_at_course,
      club: registration.club && { id: registration.club.id, name: registration.club.name },
      lizenznummer: registration.referee&.lizenznummer,
      desired_license_level_id: registration.desired_license_level_id,
      status: registration.status,
      result: registration.result,
      test_version: registration.test_version,
      points: registration.points&.to_f,
      custom_answers: registration.custom_answers.slice(*keys)
    }
  end
end
