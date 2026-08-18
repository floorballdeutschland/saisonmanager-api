require 'test_helper'

# Die Dublettenprüfung beim Anlegen eines Spielers (PlayersController#admin_player_update)
# nannte bis hierher nur die id des vorhandenen Profils: „Es existiert ein Spieler
# mit diesen Daten (ID: 212). Anlegen nicht möglich."
#
# Für einen Vereinsmanager war das eine Sackgasse. Am 18.08.2026 stand ein VM
# genau davor: Das Profil gehörte einem anderen Verein und war dort kurz zuvor
# deaktiviert worden, also fand er es weder in seiner Spielerliste noch über die
# Spielersuche des Transferantrags (die sucht in `Player.active`). Die Meldung
# sagt jetzt, was als Nächstes zu tun ist.
#
# Eigene Datei, weil players_controller_test.rb sonst über Metrics/ClassLength läuft.
class PlayersCreateDuplicateTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @vm = create(:user, :vm, club_id: @club.id)
    login_as(@vm)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def anlegen_versuchen(player)
    post '/api/v2/admin/players.json',
         params: { club_id: @club.id, first_name: player.first_name, last_name: player.last_name,
                   birthdate: player.birthdate.to_s, gender: player.gender, nation_id: player.nation_id },
         as: :json
  end

  def meldung
    JSON.parse(response.body)['message']
  end

  test 'deaktiviertes Profil verweist auf die SBK und nennt die Spieler-ID' do
    fremder_verein = create(:club)
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => fremder_verein.id, 'home_club' => true,
                                 'created_at' => 3.years.ago.iso8601,
                                 'valid_until' => 1.day.ago.iso8601 }],
                       deactivated_at: 1.day.ago)

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'SBK', meldung
    assert_match "Spieler-ID #{vorhanden.id}", meldung
    'Es darf kein zweites Profil entstanden sein'
  end

  test 'aktives Profil eines anderen Vereins verweist auf den Transferantrag' do
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => create(:club).id, 'home_club' => true,
                                 'created_at' => 1.year.ago.iso8601 }])

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'Transferantrag', meldung
    assert_match "Spieler-ID #{vorhanden.id}", meldung
  end

  test 'Profil des eigenen Vereins verweist auf die Spielerliste' do
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                 'created_at' => 1.year.ago.iso8601 }])

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'Spielerliste', meldung
    assert_no_match(/Transferantrag/, meldung)
  end

  # Eine abgelaufene Zugehörigkeit zählt nicht als „in diesem Verein": In der
  # eigenen Spielerliste taucht das Profil nicht mehr auf, dort zu suchen wäre
  # ein Fehlhinweis.
  test 'abgelaufene eigene Zugehoerigkeit verweist nicht auf die Spielerliste' do
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                 'created_at' => 3.years.ago.iso8601,
                                 'valid_until' => 1.year.ago.iso8601 }])

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'Transferantrag', meldung
  end

  test 'ohne Dublette wird weiterhin angelegt' do
    post '/api/v2/admin/players.json',
         params: { club_id: @club.id, first_name: 'Neue', last_name: 'Spielerin',
                   birthdate: '2001-10-16', gender: 'w', nation_id: '1' },
         as: :json

    assert_response :created
    assert Player.exists?(first_name: 'Neue', last_name: 'Spielerin')
  end
end
