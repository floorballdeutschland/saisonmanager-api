require 'test_helper'

# Die Dublettenprüfung beim Anlegen eines Spielers (PlayersController#admin_player_update)
# nannte bis hierher nur die id des vorhandenen Profils: „Es existiert ein Spieler
# mit diesen Daten (ID: 212). Anlegen nicht möglich."
#
# Für einen Vereinsmanager war das eine Sackgasse. Am 18.08.2026 stand ein VM
# genau davor: Das Profil gehörte einem anderen Verein und war dort kurz zuvor
# deaktiviert worden, also fand er es weder in seiner Spielerliste noch über die
# Spielersuche des Transferantrags (die suchte in `Player.active`). Die Meldung
# sagt jetzt, was als Nächstes zu tun ist.
#
# Seit api#472 ist die Deaktivierung nur noch eine Kennzeichnung der Vereinsansicht:
# Die Suche des Transferantrags findet solche Profile wieder, und ein Transfer ist
# möglich. Deshalb verweist die Meldung auch bei einem deaktivierten Profil auf den
# regulären Weg statt an die SBK; die Kennzeichnung kommt nur als Zusatz dazu.
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

  # Der Fall vom 18.08.2026, jetzt unter der neuen Semantik: Das deaktivierte Profil
  # eines fremden Vereins ist über den Transferantrag erreichbar, die Meldung darf den
  # VM also nicht mehr an die SBK abschieben. Die Kennzeichnung wird trotzdem genannt,
  # sonst wundert er sich, warum das Profil in keiner Vereinsliste steht.
  test 'deaktiviertes Profil eines fremden Vereins verweist auf den Transferantrag' do
    fremder_verein = create(:club)
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => fremder_verein.id, 'home_club' => true,
                                 'created_at' => 3.years.ago.iso8601 }],
                       deactivated_at: 1.day.ago)

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'Transferantrag', meldung
    assert_match 'deaktiviert', meldung
    assert_match "Spieler-ID #{vorhanden.id}", meldung
    assert_no_match(/kein zweites Profil/, meldung)
  end

  # Altbestand: Vor api#472 hat die Deaktivierung die Zugehörigkeit mitgeschlossen.
  # In der VM-Spielerliste steht das Profil trotzdem, denn
  # `Club#players(include_deactivated: true)` nimmt genau diese Zugehörigkeit mit.
  # Ein Transferantrag gegen den eigenen Verein wäre hier der falsche Hinweis.
  test 'von der Deaktivierung geschlossene eigene Zugehoerigkeit verweist auf die Spielerliste' do
    geschlossen_am = 1.day.ago
    vorhanden = create(:player,
                       clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                 'created_at' => 3.years.ago.iso8601,
                                 'valid_until' => geschlossen_am.iso8601,
                                 'valid_set_by' => @vm.id }],
                       deactivated_at: geschlossen_am,
                       deactivated_by: @vm.id)

    anlegen_versuchen(vorhanden)

    assert_response :unprocessable_entity
    assert_match 'Spielerliste', meldung
    assert_match 'deaktiviert', meldung
    assert_no_match(/Transferantrag/, meldung)
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
