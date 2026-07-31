require 'test_helper'

# Alle Verbandseinstellungen eines Spiels stammen vom LV des Spielbetriebs, dem
# die Liga gehört – nie vom LV des Ausrichtervereins. Die Zuständigkeit folgt der
# Liga, nicht dem Hallenstandort: Eine Landes-SBK verantwortet ausschließlich den
# Spielbetrieb ihrer eigenen Ligen.
#
# Aufgebaut wie der gemeldete Fall: Bundesligaspiel in der Halle eines Vereins,
# der einem anderen Landesverband angehört. Beide LV pflegen eine eigene
# Checkliste, damit eine Verwechslung sofort auffällt.
class GamesChecklistSourceTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)

    # LV des Spielbetriebs (z. B. FD, Betreiber der 1. FBL)
    @operation_sa = create(:state_association, sbk_email: 'sbk-spielbetrieb@example.de')
    @operation_item = @operation_sa.checklist_items.create!(question: 'Spielbetriebs-Frage?', position: 1)
    @go = create(:game_operation, state_association_id: @operation_sa.id)
    @league = create(:league, game_operation: @go)

    # LV des Ausrichtervereins (z. B. NRW), zuständig nur für eigene Ligen
    @host_sa = create(:state_association, sbk_email: 'sbk-ausrichter@example.de', scan_required: true)
    @host_sa.checklist_items.create!(question: 'Ausrichter-Frage?', position: 1)
    @club = create(:club, state_association_id: @host_sa.id, contact_email: 'ausrichter@example.de')

    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      game_number: '101',
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      referee1_string: '12345 Eree, Ref'
    )
  end

  test 'Game#state_association ist der LV des Spielbetriebs' do
    assert_equal @operation_sa, @game.state_association
  end

  test 'der Spielbericht zeigt die Checkliste des Spielbetriebs' do
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['checklist_active']
    assert_equal(['Spielbetriebs-Frage?'], body['checklist_items'].map { |i| i['question'] })
  end

  test 'der Abschluss verlangt die Checkliste des Spielbetriebs' do
    login(create(:user, :admin))

    # Antwort auf die Ausrichter-Frage genügt nicht.
    host_item = @host_sa.checklist_items.first
    @game.update!(checklist_answers: [
      { 'item_id' => host_item.id, 'question' => host_item.question, 'answer' => true }
    ])
    close_match_record
    assert_response :unprocessable_entity

    @game.update!(checklist_answers: [
      { 'item_id' => @operation_item.id, 'question' => @operation_item.question, 'answer' => true }
    ])
    close_match_record
    assert_response :success
  end

  test 'die Bestätigungsmail geht an den Ausrichter, mit der Checkliste des Spielbetriebs' do
    login(create(:user, :admin))
    @game.update!(checklist_answers: [
      { 'item_id' => @operation_item.id, 'question' => @operation_item.question, 'answer' => false }
    ])

    perform_enqueued_jobs do
      close_match_record
    end
    assert_response :success

    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Spielbericht Nr. 101 eingereicht') }
    assert_not_nil mail
    # Empfänger bleibt der Ausrichterverein, die SBK-Kopie geht an den Spielbetrieb.
    assert_equal ['ausrichter@example.de'], mail.to
    assert_equal ['sbk-spielbetrieb@example.de'], mail.bcc
    assert_includes mail.body.encoded, 'Spielbetriebs-Frage?'
    assert_not_includes mail.body.encoded, 'Ausrichter-Frage?'
  end

  test 'die Einspruchsseite zeigt die Checkliste des Spielbetriebs' do
    raw_token = SecureRandom.urlsafe_base64(32)
    @game.update_columns(checklist_veto_token_digest: Digest::SHA256.hexdigest(raw_token))

    get "/api/v2/games/#{@game.id}/checklist_veto",
        params: { token: raw_token }, headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }

    assert_response :success
    questions = JSON.parse(response.body)['checklist_items'].map { |i| i['question'] }
    assert_equal ['Spielbetriebs-Frage?'], questions
  end

  test 'die Scan-Pflicht des Ausrichter-LV greift nicht' do
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    # scan_required steht nur am Ausrichter-LV, nicht am Spielbetrieb.
    assert_equal false, JSON.parse(response.body)['scan_required']
  end

  private

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
