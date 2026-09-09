require 'test_helper'

# Anschrift des Vereins und die Pflichtangaben der Vereinsmaske (#641).
#
# Der abgebende Landesverband stellt bei einem Transfer eine Rechnung an den
# aufnehmenden Verein. Dafuer braucht er eine ladungsfaehige Anschrift und einen
# Kontakt -- beides gab es am Verein bisher nur halb (Kontakt-E-Mail, sonst
# nichts). Die Maske gibt deshalb erst frei, wenn alle Pflichtangaben stehen.
#
# Eigene Datei und nicht im clubs_controller_test: Die Testklasse dort steht
# dicht unter Metrics/ClassLength (Max 1000, siehe .rubocop_todo.yml).
class ClubAddressTest < ActionDispatch::IntegrationTest
  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  # Vollstaendiger Satz. Wer eine einzelne Angabe pruefen will, uebergibt sie
  # leer.
  def create_club_params(state_association_id:, **club_attrs)
    {
      id: 0,
      club: { name: 'Neuer Verein', short_name: 'NV', long_name: 'Neuer Verein e.V.',
              state: 'de-ni', state_association_id: state_association_id,
              street: 'Musterweg', house_number: '1', postcode: '30159', city: 'Hannover',
              contact_email: 'verein@example.org' }.merge(club_attrs)
    }
  end

  # Die Meldung nennt die fehlenden Angaben, sonst raet der Verein, woran es
  # liegt.
  test 'admin_club_update speichert nicht mit geleerter Anschrift' do
    club = create(:club, :mit_stammdaten)
    login(create(:user, :vm, club_id: club.id))

    post '/api/v2/admin/clubs',
         params: { id: club.id, club: { name: club.name, street: '', postcode: '  ' } },
         as: :json

    assert_response :unprocessable_entity
    meldung = JSON.parse(response.body)['message']
    assert_match 'Straße', meldung
    assert_match 'Postleitzahl', meldung
    assert_no_match(/Ort/, meldung, 'nur die fehlenden Angaben nennen')
    assert_equal 'Musterweg', club.reload.street, 'nichts gespeichert'
  end

  # Ein Verein aus dem Altbestand traegt die Anschrift nicht -- es gibt keinen
  # Datenlauf dazu. Er kommt an der Maske erst wieder vorbei, wenn er sie
  # nachtraegt, und zwar auch dann, wenn er eigentlich nur den Namen aendern
  # wollte. Genau das ist der Zweck der Regel.
  test 'admin_club_update speichert einen Bestandsverein erst mit Anschrift' do
    club = create(:club, long_name: nil, street: nil, postcode: nil, city: nil, contact_email: nil)
    login(create(:user, :vm, club_id: club.id))

    post '/api/v2/admin/clubs',
         params: { id: club.id, club: { name: 'Neuer Name' } },
         as: :json

    assert_response :unprocessable_entity
    assert_not_equal 'Neuer Name', club.reload.name
  end

  # Der Verein pflegt seine Anschrift selbst: Sie steht in BEIDEN Fassungen der
  # erlaubten Felder, nicht nur in der des Verbands (restricted_club_params).
  test 'admin_club_update laesst den VM die Anschrift pflegen' do
    club = create(:club, :mit_stammdaten)
    login(create(:user, :vm, club_id: club.id))

    post '/api/v2/admin/clubs',
         params: { id: club.id,
                   club: { name: club.name, long_name: 'Neuer Name e.V.', street: 'Neue Gasse',
                           house_number: '7a', postcode: '20095', city: 'Hamburg',
                           contact_email: 'post@example.org' } },
         as: :json

    assert_response :success
    club.reload
    assert_equal ['Neue Gasse', '7a', '20095', 'Hamburg'],
                 [club.street, club.house_number, club.postcode, club.city]
    assert_equal 'Neue Gasse', JSON.parse(response.body)['street'],
                 'die Antwort traegt die Anschrift, sonst leert das Formular sie wieder'
  end

  test 'admin_club_update legt keinen Verein ohne Kontakt-E-Mail an' do
    sa = create(:state_association)
    create(:game_operation, state_association_id: sa.id)
    login(create(:user, :admin))

    assert_no_difference 'Club.count' do
      post '/api/v2/admin/clubs', params: create_club_params(state_association_id: sa.id, contact_email: '')
    end

    assert_response :unprocessable_entity
    assert_match 'Kontakt-E-Mail', JSON.parse(response.body)['message']
  end

  test 'admin_club_update legt einen Verein mit vollstaendiger Anschrift an' do
    sa = create(:state_association)
    create(:game_operation, state_association_id: sa.id)
    login(create(:user, :admin))

    post '/api/v2/admin/clubs', params: create_club_params(state_association_id: sa.id)

    assert_response :created
    club = Club.find(JSON.parse(response.body)['id'])
    assert_equal %w[Musterweg 1 30159 Hannover],
                 [club.street, club.house_number, club.postcode, club.city]
  end

  # Engeres Gate als der Rest der Stammdaten: Ein fremder Landesverband darf
  # ueber eine Vereins-Freigabe die Stammdaten lesen, aber die Freigabe ist
  # keine fuer die Wohnanschrift eines Vorstandsmitglieds. Gleiche Regel wie bei
  # `admin_club_managers`, wo dieselbe Ueberlegung schon getroffen wurde.
  test 'admin_club haelt die Anschrift vom freigegebenen Fremdverband zurueck' do
    create(:setting, current_season_id: '18')
    eigen_sa = create(:state_association)
    create(:game_operation, state_association_id: eigen_sa.id)
    club = create(:club, :mit_stammdaten, state_association_id: eigen_sa.id)

    fremd_sa = create(:state_association)
    fremd_go = create(:game_operation, state_association_id: fremd_sa.id)
    StateAssociationRelease.create!(grantor_state_association_id: eigen_sa.id,
                                    recipient_game_operation_id: fremd_go.id,
                                    season_id: Setting.current_season_id)
    login(create(:user, :sbk_scoped, game_operation_id: fremd_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success, 'die Stammdaten bleiben ueber die Freigabe lesbar'
    body = JSON.parse(response.body)
    assert_equal club.name, body['name']
    assert_nil body['street']
    assert_nil body['postcode']
    assert_nil body['city']
  end

  test 'admin_club liefert die Anschrift mit' do
    club = create(:club, :mit_stammdaten, street: 'Musterweg', house_number: '1',
                                          postcode: '30159', city: 'Hannover')
    login(create(:user, :vm, club_id: club.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[Musterweg 1 30159 Hannover],
                 body.values_at('street', 'house_number', 'postcode', 'city')
  end
end
