module Admin
  # Schiedsrichterkurse in der Verwaltung (RSK, Admin). Rechte und Schalter:
  # RefereeCoursePolicy.
  class RefereeCoursesController < ApplicationController
    before_action :set_policy
    before_action :require_access!
    before_action :set_course, only: %i[show update destroy]

    PERMITTED = [
      :title, :course_type, :state_association_id, :hosting_club_id, :prerequisite_course_id,
      :prerequisites_note, :format, :online_platform, :registration_mode, :min_participants,
      :max_participants, :registration_opens_at, :registration_deadline, :cancellation_deadline,
      :min_age, :fee_member_cents, :fee_non_member_cents, :fee_only_on_license, :no_show_billable,
      :bill_state_association, :fee_note, :public, :status, :contact_email, :description,
      { license_level_ids: [], partner_state_association_ids: [],
        sessions: %i[starts_at ends_at format location online_url] }
    ].freeze

    # GET /api/v2/admin/referee_courses
    def index
      courses = @policy.scope.includes(:state_association).ordered
      courses = courses.where(status: params[:status]) if params[:status].present?
      courses = courses.where(state_association_id: params[:state_association_id]) if params[:state_association_id].present?
      if params[:from].present?
        from = Date.iso8601(params[:from])
        courses = courses.where('ends_on IS NULL OR ends_on >= ?', from)
      end
      courses = courses.to_a.select(&:process_enabled?)
      counts = RefereeCourseRegistration.where(referee_course_id: courses.map(&:id))
                                        .group(:referee_course_id, :status).count

      render json: courses.map { |course| course.summary_hash.merge(registration_counts(counts, course.id)) }
    rescue Date::Error
      render json: { error: 'Ungültiges Datum' }, status: :unprocessable_entity
    end

    # GET /api/v2/admin/referee_courses/options
    # Auswahllisten fuer die Kursmaske: die LV, denen das Konto Kurse zuordnen
    # darf (bundesweit nur Admin/FD-RSK), alle LV fuer die Partnerwahl und die
    # aktiven Lizenzstufen.
    def options
      all = StateAssociation.order(:name).map { |sa| { id: sa.id, name: sa.name } }
      assignable = all.select { |sa| @policy.assign_state_association?(sa[:id]) }
      render json: {
        state_associations: assignable,
        partner_state_associations: all,
        national_allowed: @policy.assign_state_association?(nil),
        license_levels: RefereeLicenseLevel.where(active: true).ordered.map { |l| { id: l.id, name: l.name } },
        course_types: RefereeCourse::COURSE_TYPES
      }
    end

    # GET /api/v2/admin/referee_courses/:id
    def show
      render json: course_json(@course)
    end

    # POST /api/v2/admin/referee_courses
    def create
      course = RefereeCourse.new(course_params.merge(created_by_user: current_user))
      return forbidden unless @policy.assign_state_association?(course.state_association_id)

      RefereeCourse.transaction do
        course.save!
        copy_field_templates(course)
      end
      render json: course_json(course), status: :created
    rescue ActiveRecord::RecordInvalid
      render json: { error: course.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # PATCH /api/v2/admin/referee_courses/:id
    def update
      attrs = course_params
      if attrs.key?(:state_association_id) &&
         attrs[:state_association_id].presence&.to_i != @course.state_association_id &&
         !@policy.assign_state_association?(attrs[:state_association_id].presence)
        return forbidden
      end
      unless @course.editable? || attrs.keys == ['status']
        return render json: { error: 'Der Kurs ist abgeschlossen und lässt sich nicht mehr ändern' },
                      status: :unprocessable_entity
      end

      if @course.update(attrs)
        render json: course_json(@course)
      else
        render json: { error: @course.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referee_courses/:id
    # Nur Entwuerfe ohne Anmeldungen; alles andere wird abgesagt (status
    # cancelled), damit Anmeldungen und Abrechnung nachvollziehbar bleiben.
    def destroy
      if @course.status != 'draft' || @course.registrations.exists?
        return render json: { error: 'Nur Entwürfe ohne Anmeldungen lassen sich löschen. Bitte absagen.' },
                      status: :unprocessable_entity
      end

      @course.destroy!
      head :no_content
    end

    private

    def set_policy
      @policy = RefereeCoursePolicy.new(current_user)
    end

    def require_access!
      forbidden unless @policy.any_access?
    end

    def set_course
      @course = RefereeCourse.find_by(id: params[:id])
      return render(json: { error: 'Kurs nicht gefunden' }, status: :not_found) if @course.nil?

      forbidden unless @policy.manage?(@course)
    end

    def forbidden
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def course_params
      attrs = params.require(:referee_course).permit(*PERMITTED).to_h
      attrs['state_association_id'] = attrs['state_association_id'].presence if attrs.key?('state_association_id')
      attrs
    end

    # Ein neuer Kurs uebernimmt die Feldvorlagen seines LV (bundesweit: die
    # Vorlagen ohne LV).
    def copy_field_templates(course)
      RefereeCourseFieldTemplate.where(state_association_id: course.state_association_id).ordered.each do |template|
        course.fields.create!(template.attributes.slice(*RefereeCourseFieldDefinition::COPIED_ATTRIBUTES))
      end
    end

    def registration_counts(counts, course_id)
      by_status = counts.select { |(id, _), _| id == course_id }.transform_keys { |(_, status)| status }
      {
        registration_counts: by_status,
        taken_seats: RefereeCourseRegistration::SEAT_STATUSES.sum { |s| by_status[s].to_i }
      }
    end

    def course_json(course)
      course.summary_hash.merge(
        hosting_club: course.hosting_club && { id: course.hosting_club.id, name: course.hosting_club.name },
        prerequisite_course: course.prerequisite_course && { id: course.prerequisite_course.id,
                                                              title: course.prerequisite_course.title },
        prerequisites_note: course.prerequisites_note,
        sessions: course.sessions,
        online_platform: course.online_platform,
        registration_opens_at: course.registration_opens_at,
        cancellation_deadline: course.cancellation_deadline,
        min_age: course.min_age,
        fee_member_cents: course.fee_member_cents,
        fee_non_member_cents: course.fee_non_member_cents,
        fee_only_on_license: course.fee_only_on_license,
        no_show_billable: course.no_show_billable,
        bill_state_association: course.bill_state_association,
        fee_note: course.fee_note,
        contact_email: course.contact_email,
        description: course.description,
        fields: course.fields.map { |f| f.definition_hash.merge(archived: f.archived_at.present?) },
        leads: course.leads.includes(:user).map do |lead|
          { id: lead.id, user_id: lead.user_id, name: lead.user.fullname.strip.presence || lead.user.user_name,
            lead: lead.lead }
        end,
        taken_seats: course.taken_seats,
        free_seats: course.free_seats,
        created_at: course.created_at,
        updated_at: course.updated_at
      )
    end
  end
end
