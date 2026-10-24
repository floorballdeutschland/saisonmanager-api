# Einwilligung der Erziehungsberechtigten zu einer Kursanmeldung (unter 16).
# Der Link aus der Mail ist die einzige Berechtigung. GET zeigt nur an und
# verbraucht nichts, weil Mailprogramme Links vorab abrufen; erst POST willigt
# ein.
class PublicCourseGuardianConsentsController < ApplicationController
  skip_before_action :authenticate_user

  # GET /api/v2/public/course_guardian_consents/:token
  def show
    registration = RefereeCourseRegistrar.find_by_guardian_token(params[:token])
    return render json: { error: 'Der Link ist ungültig oder abgelaufen' }, status: :not_found if registration.nil?

    course = registration.referee_course
    render json: {
      name: "#{registration.vorname} #{registration.nachname}",
      club: registration.club&.name,
      course: course.offer_hash.slice(:title, :course_type, :format, :sessions, :starts_on, :ends_on,
                                      :fee_member_cents, :fee_non_member_cents, :contact_email, :description)
    }
  end

  # POST /api/v2/public/course_guardian_consents/:token
  def create
    result = RefereeCourseRegistrar.confirm_guardian(params[:token])
    return render json: { error: result.error }, status: :not_found unless result.success?

    render json: { status: result.registration.status }
  end
end
