# Bestaetigen und Abmelden einer oeffentlichen Kursanmeldung ueber die Links
# aus den Mails. Der Link ist die Berechtigung. GET zeigt nur an und
# veraendert nichts (Mailprogramme rufen Links vorab ab), erst POST handelt.
class PublicCourseRegistrationsController < ApplicationController
  skip_before_action :authenticate_user

  # GET /api/v2/public/course_registrations/confirm/:token
  def show_confirm
    registration = RefereeCourseRegistrar.find_pending(
      params[:token], status: 'pending_email', digest_column: :email_confirmation_token_digest,
                      expiry_column: :email_confirmation_expires_at
    )
    render_info(registration)
  end

  # POST /api/v2/public/course_registrations/confirm/:token
  def confirm
    result = RefereeCourseRegistrar.confirm_email(params[:token])
    return render json: { error: result.error }, status: :not_found unless result.success?

    render json: { status: result.registration.status }
  end

  # GET /api/v2/public/course_registrations/cancel/:token
  def show_cancel
    registration = RefereeCourseRegistrar.find_by_cancel_token(params[:token])
    return render_info(nil) if registration.nil?

    deadline = registration.referee_course.cancellation_deadline
    render_info(registration, late: deadline.present? && Time.current > deadline)
  end

  # POST /api/v2/public/course_registrations/cancel/:token
  def cancel
    result = RefereeCourseRegistrar.cancel_by_token(params[:token])
    return render json: { error: result.error }, status: :unprocessable_entity unless result.success?

    render json: { status: result.registration.status, late_cancellation: result.registration.late_cancellation? }
  end

  private

  def render_info(registration, extra = {})
    return render json: { error: 'Der Link ist ungültig oder abgelaufen' }, status: :not_found if registration.nil?

    course = registration.referee_course
    render json: {
      name: "#{registration.vorname} #{registration.nachname}",
      status: registration.status,
      course: course.offer_hash.slice(:id, :title, :course_type, :format, :sessions, :starts_on, :contact_email)
    }.merge(extra)
  end
end
