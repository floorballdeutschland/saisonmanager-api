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
    end.sort_by { |s| -(s[:season_id] || 0) }

    render json: result
  end

  # GET /api/v2/referee/history/tests
  # Returns all completed online test attempts for the referee.
  def tests
    attempts = OnlineTestAttempt
                 .where(referee: @referee, status: 'completed')
                 .includes(:online_test)
                 .order(completed_at: :desc)

    render json: attempts.map { |a| test_attempt_summary(a) }
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

  def test_attempt_summary(attempt)
    test = attempt.online_test
    {
      id: attempt.id,
      online_test_id: test.id,
      test_name: test.name,
      lizenzstufe: test.lizenzstufe,
      attempt_number: attempt.attempt_number,
      completed_at: attempt.completed_at&.iso8601,
      error_points: attempt.error_points,
      passed: attempt.passed?,
      pass_threshold_points: test.pass_threshold_points
    }
  end
end
