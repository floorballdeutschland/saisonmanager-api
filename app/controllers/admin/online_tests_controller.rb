module Admin
  class OnlineTestsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_rsk!
    before_action :set_test, only: %i[show update destroy publish results]

    # GET /api/v2/admin/online_tests
    def index
      tests = OnlineTest.all
      tests = tests.where(lizenzstufe: params[:lizenzstufe]) if params[:lizenzstufe].present?
      render json: tests.map(&:summary_hash)
    end

    # GET /api/v2/admin/online_tests/:id
    def show
      render json: @test.full_hash
    end

    # POST /api/v2/admin/online_tests
    def create
      test = OnlineTest.new(test_params)
      test.created_by = current_user.id
      if test.save
        render json: test.summary_hash, status: :created
      else
        render json: { errors: test.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /api/v2/admin/online_tests/:id
    def update
      if @test.update(test_params)
        render json: @test.summary_hash
      else
        render json: { errors: @test.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/online_tests/:id
    def destroy
      @test.destroy
      head :no_content
    end

    # POST /api/v2/admin/online_tests/:id/publish
    def publish
      if @test.update(status: 'published')
        render json: @test.summary_hash
      else
        render json: { errors: @test.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # GET /api/v2/admin/online_tests/:id/results
    def results
      assignments = @test.assignments.includes(:referee)
      threshold = @test.pass_threshold_points
      attempts_by_referee = @test.attempts.where(status: 'completed')
                                          .group_by(&:referee_id)

      rows = assignments.map do |a|
        ref_attempts = (attempts_by_referee[a.referee_id] || []).sort_by(&:attempt_number)
        best = ref_attempts.min_by { |att| att.error_points || Float::INFINITY }
        passed = if best&.error_points.present? && threshold.present?
                   best.error_points <= threshold
                 end
        {
          referee_id: a.referee_id,
          nachname: a.referee.nachname,
          vorname: a.referee.vorname,
          lizenznummer: a.referee.lizenznummer,
          lizenzstufe: a.referee.lizenzstufe,
          attempt_count: ref_attempts.size,
          best_error_points: best&.error_points,
          passed:,
          attempts: ref_attempts.map { |att| att.to_hash }
        }
      end

      render json: {
        test: @test.summary_hash,
        penalty_options: OnlineTest::PENALTY_OPTIONS,
        results: rows
      }
    end

    private

    def set_test
      @test = OnlineTest.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def test_params
      params.require(:online_test).permit(
        :name, :lizenzstufe, :time_limit_minutes, :max_attempts,
        :pass_threshold_points, :deadline, :status
      )
    end

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
