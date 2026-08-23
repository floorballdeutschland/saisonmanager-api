require 'test_helper'

# Selfservice: Der Schiedsrichter stellt den Korrekturantrag im eigenen Profil.
class RefereeChangeRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @state_association = create(:state_association, rsk_email: 'rsk@lv.example')
    @club = create(:club, name: 'Eigener Verein', state_association: @state_association)
    @other_club = create(:club, name: 'Neuer Verein', state_association: @state_association)
    @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel',
                                geburtsdatum: Date.new(1990, 1, 1),
                                club: @club, email: 'schiri@example.com')
    @user = referee_user(@referee)
  end

  test 'Profil liefert die eigenen Korrekturantraege' do
    RefereeChangeRequest.create!(referee: @referee, correction_type: 'nachname', new_value: 'Musterfrau')

    login(@user)
    get '/api/v2/referee/profile'

    assert_response :success
    requests = JSON.parse(response.body)['change_requests']
    assert_equal 1, requests.size
    assert_equal 'nachname', requests.first['correction_type']
    assert_equal 'Beispiel', requests.first['current_value']
    assert_equal 'Musterfrau', requests.first['requested_value']
  end

  test 'Profil nennt den eigenen Verein mit ID' do
    login(@user)
    get '/api/v2/referee/profile'

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @club.id, body['club_id']
    assert_equal 'Eigener Verein', body['verein']
  end

  test 'Antrag anlegen liefert die Antragsliste und verschickt eine Mail an die RSK' do
    login(@user)

    assert_enqueued_emails 1 do
      post '/api/v2/referee/change_requests',
           params: { change_request: { correction_type: 'nachname', new_value: 'Musterfrau',
                                       reason: 'Heirat' } }
    end

    assert_response :created
    requests = JSON.parse(response.body)['change_requests']
    assert_equal 1, requests.size
    assert_equal 'pending', requests.first['status']
    assert_equal @user.id, RefereeChangeRequest.last.requested_by_user_id
  end

  test 'Vereinswechsel wird mit dem Zielverein beantragt' do
    login(@user)

    post '/api/v2/referee/change_requests',
         params: { change_request: { correction_type: 'verein', new_club_id: @other_club.id } }

    assert_response :created
    entry = JSON.parse(response.body)['change_requests'].first
    assert_equal @other_club.id, entry['new_club_id']
    assert_equal 'Neuer Verein', entry['requested_value']
    # Der Verein wechselt erst mit der Genehmigung.
    assert_equal @club.id, @referee.reload.club_id
  end

  test 'Antrag ohne Aenderung wird abgewiesen und verschickt keine Mail' do
    login(@user)

    assert_enqueued_emails 0 do
      post '/api/v2/referee/change_requests',
           params: { change_request: { correction_type: 'vorname', new_value: 'Anna' } }
    end

    assert_response :unprocessable_entity
  end

  test 'unbekanntes Feld wird abgewiesen' do
    login(@user)

    post '/api/v2/referee/change_requests',
         params: { change_request: { correction_type: 'lizenzstufe', new_value: 'A' } }

    assert_response :unprocessable_entity
  end

  test 'Antrag laesst sich zurueckziehen, entschiedener nicht' do
    request = RefereeChangeRequest.create!(referee: @referee, correction_type: 'nachname',
                                           new_value: 'Musterfrau')
    login(@user)

    delete "/api/v2/referee/change_requests/#{request.id}"
    assert_response :success
    assert_equal 'withdrawn', request.reload.status

    delete "/api/v2/referee/change_requests/#{request.id}"
    assert_response :unprocessable_entity
  end

  test 'zweiter Antrag zum selben Feld wird abgewiesen' do
    login(@user)
    params = { change_request: { correction_type: 'nachname', new_value: 'Musterfrau' } }

    post '/api/v2/referee/change_requests', params: params
    assert_response :created

    post '/api/v2/referee/change_requests', params: params
    assert_response :unprocessable_entity
  end

  # Doppelklick: Bei zwei gleichzeitigen Anfragen sieht die Vorpruefung
  # no_open_request den ersten Antrag noch nicht, und erst der Teilindex haelt
  # den zweiten. Hier nachgestellt, indem die Vorpruefung ins Leere greift; ohne
  # den rescue im Controller waere die Antwort ein 500er.
  test 'gleichzeitiger zweiter Antrag meldet 422 statt eines Serverfehlers' do
    login(@user)
    params = { change_request: { correction_type: 'nachname', new_value: 'Musterfrau' } }

    post '/api/v2/referee/change_requests', params: params
    assert_response :created

    RefereeChangeRequest.stub(:pending, RefereeChangeRequest.none) do
      post '/api/v2/referee/change_requests', params: params
    end

    assert_response :unprocessable_entity
  end

  test 'fremde Antraege sind nicht erreichbar' do
    fremd = create(:referee, club: @club)
    request = RefereeChangeRequest.create!(referee: fremd, correction_type: 'nachname', new_value: 'X')

    login(@user)
    delete "/api/v2/referee/change_requests/#{request.id}"

    assert_response :not_found
    assert_equal 'pending', request.reload.status
  end

  test 'ohne Schiri-Profil kein Zugriff' do
    login(create(:user, permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }]))

    post '/api/v2/referee/change_requests',
         params: { change_request: { correction_type: 'nachname', new_value: 'Musterfrau' } }

    assert_response :forbidden
  end

  private

  def referee_user(referee)
    create(:user, permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }], referee: referee)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
