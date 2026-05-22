class RefereeGameDayConfirmationsController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  AUTO_CONFIRM_HOURS = 48

  # GET /api/v2/referee/game_days
  def index
    game_days = GameDay
                .joins(games: :referee_assignment)
                .where(
                  'referee_assignments.status = ? AND (referee_assignments.referee1_id = :id OR referee_assignments.referee2_id = :id)',
                  'published', id: @referee.id
                )
                .where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", 60.days.ago.to_date)
                .includes(:league, :arena, :club, games: %i[home_team guest_team referee_assignment])
                .distinct
                .order('game_days.date DESC')

    confirmations = GameDayRefereeConfirmation
                    .where(game_day: game_days)
                    .group_by(&:game_day_id)

    render json: game_days.map { |gd| game_day_json(gd, confirmations[gd.id] || []) }
  end

  # POST /api/v2/referee/game_days/:game_day_id/confirm
  def confirm
    game_day = GameDay.find(params[:game_day_id])

    unless assigned_and_published?(game_day)
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    if auto_confirmed?(game_day)
      return render json: { error: 'Spieltag wurde automatisch bestätigt', auto_confirmed: true },
                    status: :unprocessable_entity
    end

    existing = GameDayRefereeConfirmation.find_by(game_day: game_day, referee: @referee)
    return render json: { confirmed_at: existing.confirmed_at.iso8601 } if existing

    confirmation = GameDayRefereeConfirmation.create!(
      game_day: game_day,
      referee: @referee,
      confirmed_at: Time.current
    )

    render json: { confirmed_at: confirmation.confirmed_at.iso8601 }, status: :created
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::RecordNotUnique
    existing = GameDayRefereeConfirmation.find_by(game_day: game_day, referee: @referee)
    render json: { confirmed_at: existing.confirmed_at.iso8601 } if existing
  end

  private

  def require_referee_account
    @referee = current_user.referee
    return render json: { error: 'Kein Schiedsrichter-Profil verknüpft' }, status: :forbidden if @referee.nil?
  end

  def assigned_and_published?(game_day)
    game_day.games
            .joins(:referee_assignment)
            .where(
              'referee_assignments.status = ? AND (referee_assignments.referee1_id = ? OR referee_assignments.referee2_id = ?)',
              'published', @referee.id, @referee.id
            )
            .exists?
  end

  def auto_confirmed?(game_day)
    return false if game_day.date.blank?

    date = Date.parse(game_day.date)
    date.to_datetime.end_of_day + AUTO_CONFIRM_HOURS.hours < Time.current
  rescue ArgumentError, TypeError => e
    Rails.logger.error(
      "[RefereeGameDayConfirmations] auto_confirmed? failed for game_day_id=#{game_day.id} " \
      "date=#{game_day.date.inspect}: #{e.class}: #{e.message}"
    )
    false
  end

  def game_day_json(game_day, day_confirmations)
    published_assignments = game_day.games
                                    .filter_map(&:referee_assignment)
                                    .select { |a| a.status == 'published' && (a.referee1_id == @referee.id || a.referee2_id == @referee.id) }

    partner_id = published_assignments
                 .filter_map { |a| a.referee1_id == @referee.id ? a.referee2_id : a.referee1_id }
                 .compact
                 .first

    my_confirmation = day_confirmations.find { |c| c.referee_id == @referee.id }
    partner_confirmation = partner_id ? day_confirmations.find { |c| c.referee_id == partner_id } : nil
    auto_conf = auto_confirmed?(game_day)

    {
      id: game_day.id,
      date: game_day.date,
      league: game_day.league&.name,
      arena: game_day.arena&.name,
      club: game_day.club&.name,
      my_confirmed_at: my_confirmation&.confirmed_at&.iso8601,
      partner_confirmed_at: partner_confirmation&.confirmed_at&.iso8601,
      auto_confirmed: auto_conf,
      games: game_day.games
                     .sort_by { |g| g.start_time || '' }
                     .map do |g|
               {
                 id: g.id,
                 game_number: g.game_number,
                 start_time: g.start_time,
                 home_team: g.home_team&.name,
                 guest_team: g.guest_team&.name,
                 result: g.result_string
               }
             end
    }
  end
end
