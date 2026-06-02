class RefereeBlockedDatesController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  def index
    from = params[:date_from].presence
    to   = params[:date_to].presence
    scope = @referee.referee_blocked_dates
    scope = scope.where('date >= ?', from) if from
    scope = scope.where('date <= ?', to)   if to
    scope = scope.where('date > ?', Date.today) unless from || to
    render json: scope.order(:date).map { |d| blocked_date_json(d) }
  end

  def create
    date = RefereeBlockedDate.new(blocked_date_params.merge(referee: @referee))
    if date.save
      render json: blocked_date_json(date), status: :created
    else
      render json: { errors: date.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def bulk_create
    dates_param = params[:dates]
    unless dates_param.is_a?(Array)
      return render json: { error: 'dates muss ein Array sein' }, status: :unprocessable_entity
    end

    created = []
    skipped = []

    dates_param.each do |raw|
      date_val = Date.iso8601(raw.to_s) rescue nil
      unless date_val
        skipped << { date: raw, reason: 'Ungültiges Datum' }
        next
      end

      record = RefereeBlockedDate.new(date: date_val, referee: @referee)
      if record.save
        created << blocked_date_json(record)
      else
        skipped << { date: date_val.iso8601, reason: record.errors.full_messages.first }
      end
    end

    render json: { created: created, skipped: skipped }, status: :ok
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
