module Admin
  class OnlineTestAssignmentsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_rsk!
    before_action :set_test

    # GET /api/v2/admin/online_tests/:online_test_id/assignments
    def index
      render json: @test.assignments.includes(:referee).map(&:to_hash)
    end

    # POST /api/v2/admin/online_tests/:online_test_id/assignments
    def create
      referee = Referee.find(params[:referee_id])
      assignment = @test.assignments.new(
        referee:,
        assigned_by: current_user.id,
        assigned_at: Time.current
      )
      if assignment.save
        render json: assignment.to_hash, status: :created
      else
        render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Schiedsrichter nicht gefunden' }, status: :not_found
    end

    # DELETE /api/v2/admin/online_tests/:online_test_id/assignments/:id
    def destroy
      assignment = @test.assignments.find(params[:id])
      assignment.destroy
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def set_test
      @test = OnlineTest.find(params[:online_test_id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
