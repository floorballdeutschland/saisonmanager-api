require 'test_helper'

# Einspruch des Ausrichtervereins gegen die von der Spielleitung beantwortete
# Spieltagscheckliste. Erreichbar ohne Benutzerkonto: der Einmal-Token aus der
# Bestätigungsmail ist die Berechtigung, dazu der öffentliche API-Key.
class GamesChecklistVetoTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id, contact_email: 'verein@example.de')
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @item1 = @sa.checklist_items.create!(question: 'Halle bespielbar?', position: 1)
    @item2 = @sa.checklist_items.create!(question: 'Zeitnehmer gestellt?', position: 2)
    @game = Game.create!(
      game_day: @game_day,
      home_team: create(:team, league: @league, club: @club),
      guest_team: create(:team, league: @league, club: @club),
      game_number: '101',
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      checklist_answers: [
        { 'item_id' => @item1.id, 'question' => @item1.question, 'answer' => true },
        { 'item_id' => @item2.id, 'question' => @item2.question, 'answer' => false }
      ]
    )
    @raw_token = SecureRandom.urlsafe_base64(32)
    @game.update_columns(checklist_veto_token_digest: Digest::SHA256.hexdigest(@raw_token))
  end

  test 'GET liefert Fragen und den Stand der Spielleitung' do
    get "/api/v2/games/#{@game.id}/checklist_veto",
        params: { token: @raw_token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body['already_submitted']
    assert_equal '101', body['game_number']
    assert_equal([@item1.question, @item2.question], body['checklist_items'].map { |i| i['question'] })
    assert_equal([true, false], body['original_answers'].map { |a| a['answer'] })
  end

  test 'GET ohne gültigen Token liefert 401' do
    get "/api/v2/games/#{@game.id}/checklist_veto",
        params: { token: 'falsch' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :unauthorized
  end

  test 'POST speichert den Einspruch und benachrichtigt' do
    assert_enqueued_emails 1 do
      post "/api/v2/games/#{@game.id}/checklist_veto",
           params: { token: @raw_token, answers: veto_answers },
           headers: { 'X-Api-Key' => API_KEY }, as: :json
    end

    assert_response :success
    @game.reload
    assert_not_nil @game.checklist_veto_submitted_at
    assert_equal([false, false], @game.checklist_veto_answers.map { |a| a['answer'] })
    # Der Stand der Spielleitung bleibt daneben erhalten.
    assert_equal([true, false], @game.checklist_answers.map { |a| a['answer'] })
  end

  test 'ein zweiter Einspruch wird abgewiesen' do
    post "/api/v2/games/#{@game.id}/checklist_veto",
         params: { token: @raw_token, answers: veto_answers },
         headers: { 'X-Api-Key' => API_KEY }, as: :json
    assert_response :success

    assert_no_enqueued_emails do
      post "/api/v2/games/#{@game.id}/checklist_veto",
           params: { token: @raw_token, answers: veto_answers },
           headers: { 'X-Api-Key' => API_KEY }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal 'Ein Einspruch wurde bereits eingereicht.', JSON.parse(response.body)['error']
  end

  test 'nicht-boolesche Antworten werden abgewiesen' do
    # Ein String "false" ist in Ruby wahr: gespeichert würde die
    # Benachrichtigung daraus „Ja" machen und die beanstandeten Punkte als leere
    # Liste ausgeben, also das Gegenteil des Einspruchs behaupten.
    assert_no_enqueued_emails do
      post "/api/v2/games/#{@game.id}/checklist_veto",
           params: { token: @raw_token,
                     answers: [{ item_id: @item1.id, question: @item1.question, answer: 'false' }] },
           headers: { 'X-Api-Key' => API_KEY }, as: :json
    end

    assert_response :unprocessable_entity
    assert_equal 'Ungültiges Format.', JSON.parse(response.body)['error']
    assert_nil @game.reload.checklist_veto_submitted_at
  end

  test 'GET meldet einen bereits eingereichten Einspruch' do
    @game.update_columns(checklist_veto_submitted_at: Time.current)

    get "/api/v2/games/#{@game.id}/checklist_veto",
        params: { token: @raw_token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal true, JSON.parse(response.body)['already_submitted']
  end

  test 'ohne erzeugten Token ist die Seite nicht erreichbar' do
    @game.update_columns(checklist_veto_token_digest: nil)

    get "/api/v2/games/#{@game.id}/checklist_veto",
        params: { token: @raw_token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :unauthorized
  end

  private

  def veto_answers
    [
      { item_id: @item1.id, question: @item1.question, answer: false },
      { item_id: @item2.id, question: @item2.question, answer: false }
    ]
  end
end
