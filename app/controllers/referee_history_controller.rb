class RefereeHistoryController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  # GET /api/v2/referee/history/games
  # Returns all games the referee was nominated for, grouped by season.
  def games
    all_games = @referee.games
                        .includes(:home_team, :guest_team, game_day: :league)
                        .joins(:game_day)
                        .order('game_days.date DESC')

    seasons_map = Setting.seasons.index_by { |s| s[:id] }

    grouped = all_games.group_by { |g| g.game_day.league&.season_id }

    result = grouped.map do |season_id, season_games|
      season_info = seasons_map[season_id]
      {
        season_id: season_id,
        season_name: season_info&.dig(:name) || season_id.to_s,
        games: season_games.map { |g| game_summary(g) }
      }
    end

    result.sort_by { |s| -(s[:season_id] || 0) }

    render json: result
  end

  # GET /api/v2/referee/history/tests
  # Liefert die eigenen Kurs-Ergebnisse aus dem CSV-Kurs-Import (unabhängig
  # vom Review-Status, damit der Schiri auch offene/abgelehnte Fälle sieht).
  def tests
    results = RefereeCourseResult
              .where(referee: @referee)
              .order(kursstichtag: :desc, created_at: :desc)

    render json: results.map { |r| course_result_summary(r) }
  end

  private

  def require_referee_account
    @referee = current_user.referee
    render json: { error: 'Kein Schiedsrichterprofil gefunden' }, status: :forbidden unless @referee
  end

  def game_summary(game)
    {
      id: game.id,
      game_number: game.game_number,
      date: game.game_day.date,
      home_team: game.home_team&.name,
      guest_team: game.guest_team&.name,
      league: game.league&.name,
      season_id: game.game_day.league&.season_id,
      result: game.result_string
    }
  end

  def course_result_summary(result)
    {
      id: result.id,
      lizenzstufe: result.lizenzstufe,
      gueltigkeit: result.gueltigkeit&.strftime('%d.%m.%Y'),
      kursstichtag: result.kursstichtag&.strftime('%d.%m.%Y'),
      status: result.status,
      applied_at: result.applied_at&.iso8601,
      rejection_reason: result.rejection_reason,
      course_data: result.course_data || {}
    }
  end
end
