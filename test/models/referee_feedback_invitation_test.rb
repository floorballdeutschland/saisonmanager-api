require 'test_helper'

class RefereeFeedbackInvitationTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game, game_day: @game_day, home_team: @home, guest_team: @guest)
  end

  test 'gespeichert wird nur der Digest, nicht der Token selbst' do
    invitation, raw_token = generate

    assert_not_equal raw_token, invitation.token_digest
    assert_equal Digest::SHA256.hexdigest(raw_token), invitation.token_digest
    assert_equal invitation, RefereeFeedbackInvitation.find_by_token(raw_token)
  end

  test 'der gespeicherte Digest taugt nicht als Token' do
    invitation, = generate

    assert_nil RefereeFeedbackInvitation.find_by_token(invitation.token_digest)
    assert_nil RefereeFeedbackInvitation.find_by_token(nil)
    assert_nil RefereeFeedbackInvitation.find_by_token('')
  end

  test 'Gueltigkeit endet nach 14 Tagen' do
    invitation, = generate

    assert_in_delta 14.days.from_now, invitation.expires_at, 5.seconds
    assert_not invitation.expired?
  end

  test 'ein neuer Link entwertet den alten' do
    _first, first_token = generate
    second, second_token = generate

    assert_nil RefereeFeedbackInvitation.find_by_token(first_token)
    assert_equal second, RefereeFeedbackInvitation.find_by_token(second_token)
    assert_equal 1, RefereeFeedbackInvitation.where(game: @game, team: @home).count
  end

  test 'ein abgelaufener Link ist nicht mehr verwendbar' do
    invitation, = generate
    invitation.update_columns(expires_at: 1.minute.ago)

    assert invitation.expired?
    assert_not invitation.usable?
  end

  test 'ein verbrauchter Link ist nicht mehr verwendbar' do
    invitation, = generate
    invitation.update_columns(used_at: Time.current)

    assert invitation.used?
    assert_not invitation.usable?
  end

  private

  def generate
    RefereeFeedbackInvitation.generate!(game: @game, team: @home, email: 'kapitaen@example.com')
  end
end
