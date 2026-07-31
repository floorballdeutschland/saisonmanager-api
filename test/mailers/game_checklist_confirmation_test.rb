require 'test_helper'

# Der Einspruchs-Link der Ausrichter-Mail muss auf die tatsächlich vorhandene
# Frontend-Route zeigen. Der frühere Pfad /spielbericht/:id/einspruch existierte
# dort nicht; weil die öffentliche Verbandsroute beliebige Segmente schluckt,
# endete er stumm auf einer leeren Seite statt auf einem Fehler.
class GameChecklistConfirmationTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id, contact_email: 'verein@example.de')
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @game = Game.create!(
      game_day: @game_day,
      home_team: create(:team, league: @league, club: @club),
      guest_team: create(:team, league: @league, club: @club),
      game_number: '101',
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
    @answers = [{ 'item_id' => 1, 'question' => 'Halle bespielbar?', 'answer' => true }]
  end

  test 'Einspruchs-Link zeigt auf die Einspruchsseite' do
    mail = GameMailer.checklist_confirmation(@game, @sa, @answers, @club, 'abc-token')

    assert_includes mail.body.encoded,
                    "#{FrontendUrl.base}/spieltagscheckliste/einspruch/#{@game.id}?token=abc-token"
    assert_not_includes mail.body.encoded, '/spielbericht/'
  end

  test 'Token wird fuer die Adresse kodiert' do
    mail = GameMailer.checklist_confirmation(@game, @sa, @answers, @club, 'a+b/c=')

    assert_includes mail.body.encoded, 'token=a%2Bb%2Fc%3D'
  end

  test 'ohne Token enthaelt die Mail keinen Einspruchs-Link' do
    mail = GameMailer.checklist_confirmation(@game, @sa, @answers, @club)

    assert_not_includes mail.body.encoded, 'einspruch'
  end
end
