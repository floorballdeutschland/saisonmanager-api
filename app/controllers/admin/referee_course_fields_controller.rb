module Admin
  # Zusatzfelder der Anmeldung eines Kurses.
  class RefereeCourseFieldsController < ApplicationController
    include RefereeCourseAccess

    before_action :require_editable_course!
    before_action :set_field, only: %i[update destroy]

    PERMITTED = [:label, :field_type, :required, :position, :help_text, :visible_to_lead,
                 :include_in_billing_export, { options: [] }].freeze

    # POST /api/v2/admin/referee_courses/:referee_course_id/fields
    def create
      field = @course.fields.new(field_params)
      # Die Spalte hat den Vorgabewert 0, ||= griffe also nie.
      field.position = (@course.fields.maximum(:position) || 0) + 1 unless field_params.key?(:position)
      return validation_error(field) unless field.save

      render json: field.definition_hash, status: :created
    end

    # PATCH /api/v2/admin/referee_courses/:referee_course_id/fields/:id
    def update
      return validation_error(@field) unless @field.update(field_params)

      render json: @field.definition_hash
    end

    # DELETE /api/v2/admin/referee_courses/:referee_course_id/fields/:id
    # Mit Anmeldungen nur archivieren: Deren Antworten bleiben lesbar.
    def destroy
      if @field.registrations_exist?
        @field.update!(archived_at: Time.current)
      else
        @field.destroy!
      end
      head :no_content
    end

    private

    def set_field
      @field = @course.fields.find_by(id: params[:id])
      render json: { error: 'Feld nicht gefunden' }, status: :not_found if @field.nil?
    end

    def field_params
      params.require(:field).permit(*PERMITTED)
    end
  end
end
