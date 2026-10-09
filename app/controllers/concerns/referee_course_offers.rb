# Gemeinsame Hilfen fuer Portal und Vereinsansicht der Schiedsrichterkurse:
# Angebote laden und eine Anmeldung fuer Anmeldende darstellen.
module RefereeCourseOffers
  extend ActiveSupport::Concern

  private

  def course_offers
    courses = RefereeCourse.upcoming_offers.includes(:state_association, :hosting_club, :fields).ordered
                           .to_a.select(&:process_enabled?)
    levels = RefereeLicenseLevel.where(id: courses.flat_map(&:license_level_ids)).index_by(&:id)
    [courses, levels]
  end

  def answers_param(key = :registration)
    raw = params.dig(key, :custom_answers)
    return nil if raw.nil?

    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  def own_registration_json(registration)
    course = registration.referee_course
    {
      id: registration.id,
      referee_course_id: registration.referee_course_id,
      course_title: course.title,
      starts_on: course.starts_on,
      vorname: registration.vorname,
      nachname: registration.nachname,
      geburtsdatum: registration.geburtsdatum,
      club: registration.club && { id: registration.club.id, name: registration.club.name },
      referee_id: registration.referee_id,
      status: registration.status,
      cancelled_at: registration.cancelled_at,
      late_cancellation: registration.late_cancellation?,
      result: registration.result,
      desired_license_level_id: registration.desired_license_level_id,
      remarks: registration.remarks,
      custom_answers: registration.custom_answers,
      fee_cents: registration.fee_cents,
      source: registration.source,
      cancellable: !registration.cancelled? && %w[published registration_closed].include?(course.status)
    }
  end

  def error_json(message, status = :unprocessable_entity)
    render json: { error: message }, status: status
  end
end
