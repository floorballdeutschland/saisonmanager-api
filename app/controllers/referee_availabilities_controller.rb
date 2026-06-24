class RefereeAvailabilitiesController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  def index
    from = params[:date_from].presence
    to   = params[:date_to].presence
    scope = @referee.referee_availabilities
    scope = scope.where('date >= ?', from) if from
    scope = scope.where('date <= ?', to)   if to
    scope = scope.where('date >= ?', Date.today) unless from || to
    render json: scope.order(:date).map { |a| availability_json(a) }
  end

  def create
    availability = RefereeAvailability.new(availability_params.merge(referee: @referee))
    if availability.save
      render json: availability_json(availability), status: :created
    else
      render json: { errors: availability.errors.full_messages }, status: :unprocessable_entity
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
      date_val = begin
        Date.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
      unless date_val
        skipped << { date: raw, reason: 'Ungültiges Datum' }
        next
      end

      record = RefereeAvailability.new(date: date_val, referee: @referee)
      if record.save
        created << availability_json(record)
      else
        skipped << { date: date_val.iso8601, reason: record.errors.full_messages.first }
      end
    end

    render json: { created: created, skipped: skipped }, status: :ok
  end

  def destroy
    availability = @referee.referee_availabilities.find(params[:id])

    # Eine bereits (vorläufig oder veröffentlicht) angesetzte Person darf ihre
    # Verfügbarkeit für diesen Termin nicht mehr zurückziehen.
    has_assignment = RefereeAssignment.where(status: %w[tentative published])
                                      .where(
                                        '(referee1_id = :id OR referee2_id = :id)',
                                        id: @referee.id
                                      )
                                      .joins(game: :game_day)
                                      .where("TO_DATE(game_days.date, 'YYYY-MM-DD') = ?", availability.date)
                                      .exists?

    if has_assignment
      render json: { error: 'Du bist an diesem Termin bereits angesetzt.' }, status: :unprocessable_entity
    else
      availability.destroy
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

  def availability_params
    params.require(:availability).permit(:date)
  end

  def availability_json(entry)
    { id: entry.id, date: entry.date.iso8601 }
  end
end
