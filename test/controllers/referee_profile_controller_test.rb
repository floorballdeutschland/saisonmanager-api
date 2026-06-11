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

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
