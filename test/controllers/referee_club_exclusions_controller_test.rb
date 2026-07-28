require 'test_helper'

class RefereeClubExclusionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @state_association = create(:state_association, rsk_email: 'ansetzung@lv.example')
    @own_club = create(:club, name: 'Eigener Verein', state_association: @state_association)
    @other_club = create(:club, name: 'Anderer Verein', state_association: @state_association)
    @referee = create(:referee, club: @own_club, email: 'schiri@example.com')
    @user = referee_user(@referee)
  end

  test 'Profil liefert den eigenen Verein als abgeleiteten Eintrag' do
    login(@user)
    get '/api/v2/referee/profile'

    assert_response :success
    entries = JSON.parse(response.body)['club_exclusions']
    assert_equal 1, entries.size
    assert_equal @own_club.id, entries.first['club_id']
    assert_equal 'own_club', entries.first['source']
    assert_equal false, entries.first['can_request_removal']
  end

  test 'Antrag anlegen liefert die aktualisierte Antragsliste und verschickt eine Mail' do
    login(@user)

    assert_enqueued_emails 1 do
      post '/api/v2/referee/club_exclusions/requests',
           params: { exclusion_request: { club_id: @other_club.id, kind: 'add', reason: 'Tochter spielt dort' } }
    end

    assert_response :created
    requests = JSON.parse(response.body)['club_exclusion_requests']
    assert_equal 1, requests.size
    assert_equal 'pending', requests.first['status']
    assert_equal 'Tochter spielt dort', requests.first['reason']
  end

  test 'Antrag ohne Begruendung wird abgewiesen' do
    login(@user)

    post '/api/v2/referee/club_exclusions/requests',
         params: { exclusion_request: { club_id: @other_club.id, kind: 'add', reason: '' } }

    assert_response :unprocessable_entity
  end

  test 'genehmigter Ausschluss taucht in der Liste auf und ist streichbar' do
    RefereeClubExclusion.create!(referee: @referee, club: @other_club, reason: 'Tochter spielt dort')

    login(@user)
    get '/api/v2/referee/profile'

    assert_response :success
    entry = JSON.parse(response.body)['club_exclusions'].find { |e| e['club_id'] == @other_club.id }
    assert_equal 'assigned', entry['source']
    assert_equal 'Tochter spielt dort', entry['reason']
    assert_equal true, entry['can_request_removal']
  end

  test 'fremde Antraege lassen sich nicht zurueckziehen' do
    other_referee = create(:referee, club: @own_club)
    foreign_request = RefereeClubExclusionRequest.create!(
      referee: other_referee, club: @other_club, kind: 'add', reason: 'Fremd'
    )

    login(@user)
    delete "/api/v2/referee/club_exclusions/requests/#{foreign_request.id}"

    assert_response :not_found
    assert_equal 'pending', foreign_request.reload.status
  end

  test 'eigenen Antrag zurueckziehen setzt den Status auf withdrawn' do
    own_request = RefereeClubExclusionRequest.create!(
      referee: @referee, club: @other_club, kind: 'add', reason: 'Doch nicht'
    )

    login(@user)
    delete "/api/v2/referee/club_exclusions/requests/#{own_request.id}"

    assert_response :success
    assert_equal 'withdrawn', own_request.reload.status
  end

  test 'Vereinsliste ist fuer Schiri-Konten erreichbar und blendet deaktivierte Vereine aus' do
    Rails.cache.delete(RefereeClubExclusionPresenter::CLUB_LIST_CACHE_KEY)
    deactivated = create(:club, name: 'Aufgeloest', deactivated_at: Time.current)

    login(@user)
    get '/api/v2/referee/clubs'

    assert_response :success
    ids = JSON.parse(response.body).map { |c| c['id'] }
    assert_includes ids, @other_club.id
    assert_not_includes ids, deactivated.id
  ensure
    Rails.cache.delete(RefereeClubExclusionPresenter::CLUB_LIST_CACHE_KEY)
  end

  test 'Konto ohne verknuepften Schiri erhaelt 403' do
    user = User.create!(
      user_name: "ohne_sr_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: []
    )

    login(user)
    post '/api/v2/referee/club_exclusions/requests',
         params: { exclusion_request: { club_id: @other_club.id, kind: 'add', reason: 'Test' } }

    assert_response :forbidden
  end

  private

  def referee_user(referee)
    User.create!(
      user_name: "sr_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [],
      referee: referee
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
