# Gemeinsame Vorbedingungen der verschachtelten Kurs-Controller
# (Felder, Anmeldungen): Kurs laden und RefereeCoursePolicy pruefen.
module RefereeCourseAccess
  extend ActiveSupport::Concern

  included do
    before_action :load_referee_course
  end

  private

  def load_referee_course
    @policy = RefereeCoursePolicy.new(current_user)
    @course = RefereeCourse.find_by(id: params[:referee_course_id])
    return render(json: { error: 'Kurs nicht gefunden' }, status: :not_found) if @course.nil?

    render json: { error: 'Nicht berechtigt' }, status: :forbidden unless @policy.manage?(@course)
  end

  def require_editable_course!
    return if @course.editable?

    render json: { error: 'Der Kurs ist abgeschlossen und lässt sich nicht mehr ändern' },
           status: :unprocessable_entity
  end

  def validation_error(record)
    render json: { error: record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  end
end
