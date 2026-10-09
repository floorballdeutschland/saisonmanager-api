module Admin
  # Feldvorlagen je Landesverband. Ein neuer Kurs uebernimmt die Vorlagen seines
  # LV. Vorlagen ohne LV gelten fuer bundesweite Kurse und sind Admin/FD-RSK
  # vorbehalten.
  class RefereeCourseFieldTemplatesController < ApplicationController
    before_action :set_policy
    before_action :set_template, only: %i[update destroy]

    PERMITTED = [:label, :field_type, :required, :position, :help_text, :visible_to_lead,
                 :include_in_billing_export, { options: [] }].freeze

    # GET /api/v2/admin/referee_course_field_templates?state_association_id=
    def index
      sa_id = params[:state_association_id].presence&.to_i
      return forbidden unless @policy.assign_state_association?(sa_id)

      render json: RefereeCourseFieldTemplate.where(state_association_id: sa_id).ordered.map(&:definition_hash)
    end

    # POST /api/v2/admin/referee_course_field_templates
    def create
      sa_id = params.dig(:field, :state_association_id).presence&.to_i
      return forbidden unless @policy.assign_state_association?(sa_id)

      template = RefereeCourseFieldTemplate.new(template_params.merge(state_association_id: sa_id))
      template.position ||= (RefereeCourseFieldTemplate.where(state_association_id: sa_id).maximum(:position) || 0) + 1
      unless template.save
        return render json: { error: template.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end

      render json: template.definition_hash, status: :created
    end

    # PATCH /api/v2/admin/referee_course_field_templates/:id
    def update
      unless @template.update(template_params)
        return render json: { error: @template.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end

      render json: @template.definition_hash
    end

    # DELETE /api/v2/admin/referee_course_field_templates/:id
    # Bereits angelegte Kurse behalten ihre kopierten Felder.
    def destroy
      @template.destroy!
      head :no_content
    end

    private

    def set_policy
      @policy = RefereeCoursePolicy.new(current_user)
    end

    def set_template
      @template = RefereeCourseFieldTemplate.find_by(id: params[:id])
      return render(json: { error: 'Vorlage nicht gefunden' }, status: :not_found) if @template.nil?

      forbidden unless @policy.assign_state_association?(@template.state_association_id)
    end

    def template_params
      params.require(:field).permit(*PERMITTED)
    end

    def forbidden
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
