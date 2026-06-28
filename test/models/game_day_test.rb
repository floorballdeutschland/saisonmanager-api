require 'test_helper'

class GameDayTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # GameDay#full_hash(with_games: true) – kein N+1 auf home_team/guest_team
  # (Issue #26). meta_hash je Spiel liest home_team/guest_team (+ club für die
  # Logo-Fallbacks); ohne Eager-Loading skaliert die Zahl der teams-Queries mit
  # der Spielanzahl. Mit includes bleibt sie konstant (je ein Preload für
  # home_team und guest_team), unabhängig von der Spielanzahl.
  # ---------------------------------------------------------------------------

  test 'full_hash(true) laedt Teams gebuendelt statt pro Spiel' do
    league = create(:league, :current_season)
    arena  = create(:arena)
    club   = create(:club)
    game_day = GameDay.create!(league:, arena:, club:, number: 1, date: '2026-01-01')

    # 4 Spiele mit je eigenen Heim-/Gastteams – ohne Preload wären das 8
    # Team-Queries (2 pro Spiel), mit Preload genau 2 (je ein IN-Query).
    4.times do |i|
      Game.create!(
        game_day:,
        home_team: create(:team, league:),
        guest_team: create(:team, league:),
        game_number: (i + 1).to_s,
        players: { 'home' => [], 'guest' => [] },
        events: []
      )
    end

    team_queries = capture_sql { game_day.full_hash(true) }
                   .count { |sql| sql =~ /\bfrom\s+"teams"/i }

    # Ohne Eager-Loading wären es 8 (2 Teams * 4 Spiele). Mit dem Preload
    # bleibt es konstant klein (Rails bündelt home_team/guest_team je in einen
    # IN-Query), unabhängig von der Spielanzahl.
    assert_operator team_queries, :<=, 2,
                    "teams-Queries skalieren mit der Spielanzahl (N+1): #{team_queries}"
  end

  private

  def capture_sql
    sqls = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:name] == 'SCHEMA'
      next if payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

      sqls << payload[:sql]
    end
    yield
    sqls
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
