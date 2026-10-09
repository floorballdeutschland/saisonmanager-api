module Admin
  # Kursleitungen eines Kurses zuordnen und entfernen (RSK, Admin). Die Rolle am
  # Konto pflegt RefereeCourseLeadAssigner mit.
  class RefereeCourseLeadsController < ApplicationController
    include RefereeCourseAccess

    before_action :require_editable_course!
    before_action :set_lead, only: %i[update destroy]

    # POST /api/v2/admin/referee_courses/:referee_course_id/leads
    # Mit `referee_id`, `user_name` oder `first_name`/`last_name`/`email`.
    def create
      attrs = params.require(:lead).permit(:referee_id, :user_name, :first_name, :last_name, :email, :lead).to_h
      result = RefereeCourseLeadAssigner.new(@course).assign(attrs.symbolize_keys)
      return render json: { error: result.error }, status: :unprocessable_entity unless result.success?

      render json: lead_json(result.lead).merge(invited: result.invited), status: :created
    end

    # PATCH /api/v2/admin/referee_courses/:referee_course_id/leads/:id
    def update
      @lead.update!(lead: ActiveModel::Type::Boolean.new.cast(params.dig(:lead, :lead)) == true)
      render json: lead_json(@lead)
    end

    # DELETE /api/v2/admin/referee_courses/:referee_course_id/leads/:id
    def destroy
      RefereeCourseLeadAssigner.remove(@lead)
      head :no_content
    end

    private

    def set_lead
      @lead = @course.leads.find_by(id: params[:id])
      render json: { error: 'Kursleitung nicht gefunden' }, status: :not_found if @lead.nil?
    end

    def lead_json(lead)
      user = lead.user
      { id: lead.id, user_id: user.id, name: user.fullname.strip.presence || user.user_name,
        user_name: user.user_name, lead: lead.lead }
    end
  end
end
