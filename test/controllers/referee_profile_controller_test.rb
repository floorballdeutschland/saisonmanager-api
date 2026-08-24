require 'test_helper'

class RefereeProfileControllerTest < ActionDispatch::IntegrationTest
  setup do
    @state_association = create(:state_association, name: 'Floorball Berlin')
    @club = create(:club, name: 'Floorball Club Berlin', state_association: @state_association)
    @referee = create(:referee,
                      vorname: 'Max',
                      nachname: 'Mustermann',
                      geburtsdatum: Date.new(1990, 5, 17),
                      lizenzstufe: 'A',
                      gueltigkeit: Date.new(2030, 6, 30),
                      club: @club)
    @user = User.create!(
      user_name: "sr_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [],
      referee: @referee
    )
  end

  test 'show liefert Ausweis-Felder (Geburtsdatum, Verein, Landesverband) des eingeloggten Schiris' do
    login(@user)
    get '/api/v2/referee/profile'
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal '17.05.1990', body['geburtsdatum']
    assert_equal 'Floorball Club Berlin', body['verein']
    assert_equal 'Floorball Berlin', body['landesverband']
    assert_equal 'A', body['lizenzstufe']
    assert_equal '30.06.2030', body['gueltigkeit']
  end

  test 'show fuer Schiri ohne Verein liefert verein und landesverband nil' do
    referee = create(:referee, vorname: 'Ohne', nachname: 'Verein', club: nil)
    user = User.create!(
      user_name: "sr_ov_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [],
      referee: referee
    )
    login(user)
    get '/api/v2/referee/profile'
    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body['verein']
    assert_nil body['landesverband']
  end

  test 'show ohne verknuepften Schiri liefert 403' do
    user = User.create!(
      user_name: "ohne_sr_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: []
    )
    login(user)
    get '/api/v2/referee/profile'
    assert_response :forbidden
  end

  test 'show liefert die Konto-Adresse als account_email mit' do
    @user.update!(email: 'konto@example.com')
    login(@user)
    get '/api/v2/referee/profile'
    assert_response :success
    assert_equal 'konto@example.com', JSON.parse(response.body)['account_email']
  end

  test 'update ignoriert ein mitgeschicktes email-Feld (Pflege nur über Mein Konto)' do
    @referee.update!(email: 'schiri@example.com')
    login(@user)

    put '/api/v2/referee/profile',
        params: { referee: { telefonnummer: '0301234567', email: 'gekapert@example.com' } },
        as: :json

    assert_response :success
    @referee.reload
    assert_equal '0301234567', @referee.telefonnummer, 'andere Felder müssen weiter änderbar sein'
    assert_equal 'schiri@example.com', @referee.email, 'email darf über das Profil nicht mehr änderbar sein'
  end

  test 'update ignoriert mitgeschickte Namensfelder (Name steht auf dem Ausweis)' do
    login(@user)

    put '/api/v2/referee/profile',
        params: { referee: { telefonnummer: '0301234567', vorname: 'Gekapert', nachname: 'Gekapert' } },
        as: :json

    assert_response :success
    @referee.reload
    assert_equal '0301234567', @referee.telefonnummer, 'andere Felder müssen weiter änderbar sein'
    assert_equal 'Max', @referee.vorname, 'vorname darf über das Profil nicht mehr änderbar sein'
    assert_equal 'Mustermann', @referee.nachname, 'nachname darf über das Profil nicht mehr änderbar sein'
  end

  test 'show liefert die Zusatzqualifikationen mit Gueltigkeit, nach Namen sortiert' do
    spielleiter = RefereeQualificationType.create!(name: 'Spielleiter', short_name: 'SL')
    beobachter  = RefereeQualificationType.create!(name: 'Beobachter', short_name: 'BEO')
    RefereeQualification.create!(referee: @referee, referee_qualification_type: spielleiter,
                                 valid_until: Date.new(2031, 6, 30))
    RefereeQualification.create!(referee: @referee, referee_qualification_type: beobachter,
                                 valid_until: Date.new(2028, 12, 31))

    login(@user)
    get '/api/v2/referee/profile'
    assert_response :success

    quals = JSON.parse(response.body)['qualifications']
    assert_equal(%w[Beobachter Spielleiter], quals.map { |q| q['qualification_type_name'] })
    assert_equal(%w[BEO SL], quals.map { |q| q['short_name'] })
    assert_equal(['31.12.2028', '30.06.2031'], quals.map { |q| q['valid_until'] })
  end

  test 'show liefert eine abgelaufene Qualifikation und eine ohne Ablaufdatum weiter' do
    abgelaufen = RefereeQualificationType.create!(name: 'Abgelaufen')
    unbefristet = RefereeQualificationType.create!(name: 'Ohne Datum')
    RefereeQualification.create!(referee: @referee, referee_qualification_type: abgelaufen,
                                 valid_until: Date.new(2020, 1, 31))
    RefereeQualification.create!(referee: @referee, referee_qualification_type: unbefristet,
                                 valid_until: nil)

    login(@user)
    get '/api/v2/referee/profile'
    assert_response :success

    quals = JSON.parse(response.body)['qualifications']
    assert_equal '31.01.2020', quals.find { |q| q['qualification_type_name'] == 'Abgelaufen' }['valid_until']
    assert_nil quals.find { |q| q['qualification_type_name'] == 'Ohne Datum' }['valid_until']
  end

  test 'show liefert eine leere Liste, wenn keine Zusatzqualifikation hinterlegt ist' do
    login(@user)
    get '/api/v2/referee/profile'
    assert_response :success
    assert_equal [], JSON.parse(response.body)['qualifications']
  end

  test 'update ignoriert mitgeschickte Qualifikationen (Pflege nur durch die RSK)' do
    typ = RefereeQualificationType.create!(name: 'Spielleiter')
    login(@user)

    put '/api/v2/referee/profile',
        params: { referee: { telefonnummer: '0301234567',
                             qualifications: [{ qualification_type_id: typ.id,
                                                valid_until: '30.06.2031' }] } },
        as: :json

    assert_response :success
    @referee.reload
    assert_equal '0301234567', @referee.telefonnummer, 'andere Felder müssen weiter änderbar sein'
    assert_empty @referee.referee_qualifications, 'Qualifikationen dürfen sich hier nicht anlegen lassen'
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
