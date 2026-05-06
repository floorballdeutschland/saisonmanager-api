class RefereeBlockedDatesController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  def index
    dates = @referee.referee_blocked_dates
                    .where('date > ?', Date.today)
                    .order(:date)
    render json: dates.map { |d| blocked_date_json(d) }
  end

  def create
    date = RefereeBlockedDate.new(blocked_date_params.merge(referee: @referee))
    if date.save
      render json: blocked_date_json(date), status: :created
    else
      render json: { errors: date.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    date = @referee.referee_blocked_dates.find(params[:id])

    has_assignment = RefereeAssignment.where(status: %w[tentative published])
                                      .where(
                                        '(referee1_id = :id OR referee2_id = :id)',
                                        id: @referee.id
                                      )
                                      .joins(game: :game_day)
                                      .where("TO_DATE(game_days.date, 'YYYY-MM-DD') = ?", date.date)
                                      .exists?

    if has_assignment
      render json: { error: 'Du bist an diesem Termin bereits eingeplant.' }, status: :unprocessable_entity
    else
      date.destroy
      head :no_content
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  def require_referee_account
    @referee = current_user.referee
    head :forbidden unless @referee
  end

  def blocked_date_params
    params.require(:blocked_date).permit(:date)
  end

  def blocked_date_json(d)
    { id: d.id, date: d.date.iso8601 }
  end
end
