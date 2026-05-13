module Admin
  class OnlineTestQuestionsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_rsk!
    before_action :set_test
    before_action :set_question, only: %i[update destroy]

    # POST /api/v2/admin/online_tests/:online_test_id/questions
    def create
      question = @test.questions.new(question_params)
      if question.save
        render json: question.to_hash, status: :created
      else
        render json: { errors: question.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /api/v2/admin/online_tests/:online_test_id/questions/:id
    def update
      if @question.update(question_params)
        render json: @question.to_hash
      else
        render json: { errors: @question.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/online_tests/:online_test_id/questions/:id
    def destroy
      @question.destroy
      head :no_content
    end

    private

    def set_test
      @test = OnlineTest.find(params[:online_test_id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def set_question
      @question = @test.questions.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def question_params
      params.require(:online_test_question).permit(:scenario, :position, rows: [:id, :label], solution: [:id, :value])
    end

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
