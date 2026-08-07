require 'test_helper'

# Sichtbarkeit der Karriere-Beendeten: Sie sind ein Register alter
# Lizenznummern, keine Betriebsdaten. Deshalb raus aus der öffentlichen Fläche
# und aus der Vereinsliste, aber auffindbar über die Lizenznummer.
class RefereeCareerVisibilityTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml

  setup do
    Rails.cache.clear
    create(:setting, current_season_id: '19')
    Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
    Rails.cache.clear

    @club = create(:club, name: 'TSV Sichtbar')
    @aktiv = create(:referee, lizenznummer: 700_001, nachname: 'Aktivsen', vorname: 'Anna',
                             gueltigkeit: Date.new(2027, 9, 30), club: @club)
    @abgelaufen = create(:referee, lizenznummer: 700_002, nachname: 'Abgelaufsen', vorname: 'Bert',
                                   gueltigkeit: Date.new(2023, 9, 30), club: @club)
    @beendet = create(:referee, lizenznummer: 700_003, nachname: 'Beendetsen', vorname: 'Clara',
                                gueltigkeit: Date.new(2022, 7, 31), club: @club)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  test 'öffentliche Autocomplete liefert Beendete nicht' do
    get '/api/v2/referees/search', params: { q: 'sen' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    nummern = response.parsed_body.map { |r| r['lizenznummer'] }

    assert_includes nummern, 700_001
    assert_includes nummern, 700_002
    assert_not_includes nummern, 700_003, 'Karriere beendet gehört nicht in die öffentliche Suche'
  end

  test 'öffentliche Autocomplete liefert Beendete auch bei Suche nach der Nummer nicht' do
    get '/api/v2/referees/search', params: { q: '700003' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_empty response.parsed_body
  end

  test 'öffentlicher Lizenzcheck antwortet für Beendete wie für eine unbekannte Nummer' do
    get '/api/v2/user/referees/700003', headers: { 'X-Api-Key' => API_KEY }

    assert_response :not_found
    assert_equal 'Lizenz nicht gefunden', response.parsed_body['error']
  end

  test 'öffentlicher Lizenzcheck antwortet für Abgelaufene weiterhin' do
    get '/api/v2/user/referees/700002', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 700_002, response.parsed_body['lizenznummer']
  end

  # Ohne Ablaufdatum ist kein beendeter Fall: Ein frisch angelegter
  # Schiedsrichter hat noch keine Gueltigkeit, bis das erste Kursergebnis kommt.
  # Verschwaende er aus der Namenssuche, waere er im Spielbericht nicht
  # eintragbar — genau dann, wenn er gebraucht wird.
  test 'Schiedsrichter ohne Ablaufdatum bleiben oeffentlich auffindbar' do
    create(:referee, lizenznummer: 700_004, nachname: 'Neusen', vorname: 'Nora',
                     gueltigkeit: nil, club: @club)

    get '/api/v2/referees/search', params: { q: 'Neusen' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_includes response.parsed_body.map { |r| r['lizenznummer'] }, 700_004
  end

  test 'Lizenzcheck antwortet ohne Ablaufdatum mit leerer Gueltigkeit' do
    create(:referee, lizenznummer: 700_005, nachname: 'Ohnesen', vorname: 'Olaf', gueltigkeit: nil)

    get '/api/v2/user/referees/700005', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_nil response.parsed_body['gueltigkeit']
  end

  test 'gemergte Dubletten tauchen oeffentlich nicht auf' do
    dublette = create(:referee, lizenznummer: 700_006, nachname: 'Dublettsen', vorname: 'Dirk',
                                gueltigkeit: Date.new(2027, 9, 30))
    dublette.update_column(:merged_into_id, @aktiv.id)

    get '/api/v2/referees/search', params: { q: 'Dublettsen' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_empty response.parsed_body
  end

  test 'VM-Vereinsliste zeigt Beendete nicht' do
    vm = User.create!(user_name: "vm_#{SecureRandom.hex(4)}", password: 'password123',
                      password_confirmation: 'password123',
                      permissions: [{ 'user_group_id' => 4, 'club_id' => @club.id }], teams: [])
    create(:referee, lizenznummer: 700_007, nachname: 'Frischsen', vorname: 'Frida',
                     gueltigkeit: nil, club: @club)
    login(vm)

    get '/api/v2/vm/referees'

    assert_response :success
    nummern = response.parsed_body.map { |r| r['lizenznummer'] }

    assert_equal [700_001, 700_002, 700_007].sort, nummern.sort
  end
end
