require 'test_helper'

# `init` ist der erste Request jedes Seitenaufbaus: Saisons, Spielbetriebe,
# Landesverbände. Fällt ein Schlüssel daraus weg, bricht das Frontend überall
# gleichzeitig, und zwar ohne Fehlermeldung, weil die Ströme im
# AssociationService dann einfach leer bleiben.
#
# Bis zum Ausbau der Informationsblatt-Links (#456) hatte der Endpunkt trotzdem
# keinen eigenen Test: Die zwei Fälle, die ihn nebenbei aufriefen, steckten im
# Test des Info-Links-Controllers und sind mit ihm gelöscht worden. Dieser Test
# hält deshalb den vollständigen Schlüsselsatz fest, statt nur die Abwesenheit
# von `info_links` zu prüfen. Ein versehentlich entfernter oder umbenannter
# Schlüssel fällt damit hier auf und nicht erst im Browser.
class SettingsControllerTest < ActionDispatch::IntegrationTest
  INIT_KEYS = %w[current_season_id game_operations seasons state_associations].freeze

  setup do
    create(:setting)
  end

  test 'init liefert genau die Schlüssel, die das Frontend erwartet' do
    login(create(:user))

    get '/api/v2/init.json'

    assert_response :success
    assert_equal INIT_KEYS, JSON.parse(response.body).keys.sort
  end

  # Die Links auf Informationsblätter sind mit #456 ausgebaut. Der Schlüssel darf
  # nicht unbemerkt zurückkommen: Das Frontend hat seine Seite der Kette
  # (Service, Modell, Pflegemaske) mit entfernt.
  test 'init liefert keine info_links mehr' do
    login(create(:user))

    get '/api/v2/init.json'

    assert_not JSON.parse(response.body).key?('info_links')
  end

  # Der Endpunkt hängt an authenticate_public_request: ohne Sitzung und ohne
  # API-Key keine Antwort. Sonst wäre der Verbandsbestand offen abrufbar.
  test 'init verlangt Sitzung oder API-Key' do
    get '/api/v2/init.json'

    assert_response :unauthorized
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
