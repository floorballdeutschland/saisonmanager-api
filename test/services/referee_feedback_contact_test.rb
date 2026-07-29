require 'test_helper'

# Auflösungskette für den Feedback-Kontakt einer Mannschaft: Kapitän*in des
# Spiels, sonst die frei eingetragene Adresse, sonst niemand.
class RefereeFeedbackContactTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club)
    @opponent = create(:team, league: @league, club: @club)
    @game_day = create(:game_day, league: @league, club: @club)
    @captain = create(:player, email: 'kapitaenin@example.com')
  end

  test 'Kapitaenin mit Mailadresse gewinnt, wenn die Mannschaft das eingestellt hat' do
    @team.update!(feedback_contact_prefer_captain: true, feedback_contact_email: 'tm@example.com')
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_id' => @captain.id, 'captain' => true }])

    recipient = RefereeFeedbackContact.new(game, @team).resolve

    assert_equal 'kapitaenin@example.com', recipient.email
    assert_equal @captain.id, recipient.player.id
    assert_equal :captain, recipient.source
  end

  test 'ohne gepflegte Mailadresse am Spielerprofil greift die eingetragene Adresse' do
    @captain.update!(email: nil)
    @team.update!(feedback_contact_prefer_captain: true, feedback_contact_email: 'tm@example.com')
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_id' => @captain.id, 'captain' => true }])

    recipient = RefereeFeedbackContact.new(game, @team).resolve

    assert_equal 'tm@example.com', recipient.email
    assert_nil recipient.player
    assert_equal :team_contact, recipient.source
  end

  test 'ohne markierte Kapitaenin greift die eingetragene Adresse' do
    @team.update!(feedback_contact_prefer_captain: true, feedback_contact_email: 'tm@example.com')
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_id' => @captain.id }])

    recipient = RefereeFeedbackContact.new(game, @team).resolve

    assert_equal 'tm@example.com', recipient.email
    assert_equal :team_contact, recipient.source
  end

  test 'Aufstellungseintrag ohne Spielerprofil laesst die Kapitaens-Auflösung leer' do
    @team.update!(feedback_contact_prefer_captain: true, feedback_contact_email: 'tm@example.com')
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_name' => 'Gastspieler', 'captain' => true }])

    recipient = RefereeFeedbackContact.new(game, @team).resolve

    assert_equal 'tm@example.com', recipient.email
  end

  test 'ohne Einstellung und ohne Adresse gibt es keinen Empfaenger' do
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_id' => @captain.id, 'captain' => true }])

    assert_nil RefereeFeedbackContact.new(game, @team).resolve
  end

  test 'ohne Kapitaens-Einstellung wird die Aufstellung nicht ausgewertet' do
    @team.update!(feedback_contact_prefer_captain: false, feedback_contact_email: 'tm@example.com')
    game = game_with_lineup([{ 'trikot_number' => 7, 'player_id' => @captain.id, 'captain' => true }])

    recipient = RefereeFeedbackContact.new(game, @team).resolve

    assert_equal 'tm@example.com', recipient.email
    assert_equal :team_contact, recipient.source
  end

  private

  def game_with_lineup(home_entries)
    create(:game,
           game_day: @game_day,
           home_team: @team,
           guest_team: @opponent,
           players: { 'home' => home_entries, 'guest' => [] })
  end
end
