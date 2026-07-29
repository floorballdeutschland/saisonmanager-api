require 'test_helper'

class RefereeFeedbackTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club)
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game, game_day: @game_day, home_team: @team)
  end

  test 'Abgabe über den Einmal-Link zählt als Einladung' do
    assert_equal 'invitation', feedback(submitted_by_email: 'kapitaen@example.com').submitted_via
    assert_equal 'invitation', feedback(submitted_by_player_id: create(:player).id).submitted_via
  end

  test 'Abgabe aus einem Benutzerkonto zählt als Konto' do
    user = create(:user)

    assert_equal 'account', feedback(submitted_by_user_id: user.id).submitted_via
  end

  test 'die Einladung gewinnt, wenn beides hinterlegt ist' do
    user = create(:user)
    entry = feedback(submitted_by_user_id: user.id, submitted_by_email: 'kapitaen@example.com')

    assert_equal 'invitation', entry.submitted_via
  end

  test 'ohne jede Herkunft wird kein Weg behauptet' do
    assert_nil feedback.submitted_via
  end

  private

  def feedback(**attrs)
    RefereeFeedback.new(game: @game, team: @team, line_rating: 7, communication_rating: 8, **attrs)
  end
end
