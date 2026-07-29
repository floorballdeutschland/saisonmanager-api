require 'test_helper'

# Einstellung je Mannschaft, wer das Schiri-Feedback abgibt. Die Werte hängen an
# der Mannschaft, nicht am Konto: Mehrere Teammanager sehen denselben Eintrag.
class UserRefereeFeedbackSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @other_league = create(:league, referee_feedback_enabled: false)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club, name: 'Mit Feedback')
    @team_without = create(:team, league: @other_league, club: @club, name: 'Ohne Feedback')
    @tm = create(:user, :tm, team_id: @team.id, email: 'tm1@example.com')
  end

  test 'Liste enthaelt nur Mannschaften in feedback-pflichtigen Ligen' do
    @tm.update!(teams: [@team.id, @team_without.id])
    login(@tm)

    get '/api/v2/user/referee_feedback_settings'

    assert_response :success
    names = JSON.parse(response.body).map { |e| e['team_name'] }
    assert_equal ['Mit Feedback'], names
  end

  test 'Kontakt speichern und wieder lesen' do
    login(@tm)

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_email: ' kapitaen@example.com ', feedback_contact_prefer_captain: true }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'kapitaen@example.com', body['feedback_contact_email']
    assert_equal true, body['feedback_contact_prefer_captain']
    assert_equal 'kapitaen@example.com', @team.reload.feedback_contact_email
    assert_equal @tm.id, @team.feedback_contact_updated_by
  end

  test 'ein zweiter Teammanager derselben Mannschaft sieht und aendert denselben Eintrag' do
    @team.update!(feedback_contact_email: 'kapitaen@example.com')
    second_tm = create(:user, :tm, team_id: @team.id, email: 'tm2@example.com')

    login(second_tm)
    get '/api/v2/user/referee_feedback_settings'
    assert_equal 'kapitaen@example.com', JSON.parse(response.body).first['feedback_contact_email']

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_email: 'neuer-kapitaen@example.com' }

    assert_response :success
    assert_equal 'neuer-kapitaen@example.com', @team.reload.feedback_contact_email
    assert_equal second_tm.id, @team.feedback_contact_updated_by
  end

  test 'ein Aufruf mit nur einem Feld laesst das andere unberuehrt' do
    @team.update!(feedback_contact_email: 'kapitaen@example.com', feedback_contact_prefer_captain: true)
    login(@tm)

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_prefer_captain: false }

    assert_response :success
    assert_equal 'kapitaen@example.com', @team.reload.feedback_contact_email
    assert_equal false, @team.feedback_contact_prefer_captain

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_email: 'neu@example.com' }

    assert_response :success
    assert_equal 'neu@example.com', @team.reload.feedback_contact_email
    assert_equal false, @team.feedback_contact_prefer_captain
  end

  test 'Mannschaften vergangener Saisons erscheinen nicht' do
    past_league = create(:league, :previous_season, referee_feedback_enabled: true)
    past_team = create(:team, league: past_league, club: @club, name: 'Alte Saison')
    @tm.update!(teams: [@team.id, past_team.id])
    login(@tm)

    get '/api/v2/user/referee_feedback_settings'

    assert_response :success
    names = JSON.parse(response.body).map { |e| e['team_name'] }
    assert_equal ['Mit Feedback'], names
  end

  test 'Vereinsmanager verwaltet die Mannschaften des eigenen Vereins' do
    vm = create(:user, :vm, club_id: @club.id, email: 'vm@example.com')
    login(vm)

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_email: 'vm-kontakt@example.com' }

    assert_response :success
    assert_equal 'vm-kontakt@example.com', @team.reload.feedback_contact_email
  end

  test 'unbekannte Mannschaft liefert 404' do
    login(@tm)

    patch '/api/v2/user/referee_feedback_settings/999999',
          params: { feedback_contact_email: 'egal@example.com' }

    assert_response :not_found
  end

  test 'fremde Mannschaft wird abgewiesen' do
    foreign_team = create(:team, league: @league, club: create(:club))
    login(@tm)

    patch "/api/v2/user/referee_feedback_settings/#{foreign_team.id}",
          params: { feedback_contact_email: 'fremd@example.com' }

    assert_response :forbidden
    assert_nil foreign_team.reload.feedback_contact_email
  end

  test 'ungueltige Adresse wird abgewiesen' do
    login(@tm)

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}",
          params: { feedback_contact_email: 'keine-adresse' }

    assert_response :unprocessable_entity
    assert_nil @team.reload.feedback_contact_email
  end

  test 'leere Adresse loescht den Kontakt' do
    @team.update!(feedback_contact_email: 'kapitaen@example.com')
    login(@tm)

    patch "/api/v2/user/referee_feedback_settings/#{@team.id}", params: { feedback_contact_email: '' }

    assert_response :success
    assert_nil @team.reload.feedback_contact_email
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
