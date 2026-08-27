require 'test_helper'

# POST /api/v2/admin/leagues/import_schedule ohne Datei.
#
# Bis 27.08.2026 prüfte die Action `current_user && params[:file].present?` in
# einer Bedingung und beantwortete den Else-Zweig pauschal mit 401
# "Nicht eingeloggt.". Der ErrorInterceptor des Frontends meldet bei 401 ab und
# leitet auf /login um, eine fehlende Datei warf also aus einer voll gültigen
# Sitzung. Auf Produktion trugen in den 30 Tagen vor dem Fix 11 von 12
# Importversuchen `"file"=>""` und endeten damit in genau diesem Rauswurf.
#
# Zweiter Teil: eine Datei, die sich nicht als Arbeitsmappe öffnen lässt.
# `Creek::Book.new` wirft darauf, bis 27.08.2026 ungefangen, sodass der globale
# StandardError-Handler daraus einen 500 „Server-Fehler." samt Sentry-Meldung
# machte. Ein verwechseltes Dateiformat las sich damit als Serverstörung.
class LeaguesScheduleImportMissingFileTest < ActionDispatch::IntegrationTest
  XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'.freeze

  setup do
    @user = User.create!(
      user_name: "importadmin_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )
  end

  test 'leerer Datei-Parameter meldet nicht ab, sondern antwortet mit 422' do
    login(@user)

    # Genau das, was die Maske schickt, wenn nichts ausgewählt wurde: den
    # Anfangswert des Formularfelds, also einen leeren String.
    post '/api/v2/admin/leagues/import_schedule', params: { file: '' }

    assert_response :unprocessable_entity
    refute_equal 401, response.status, 'Ein 401 meldet im Frontend ab'

    fehler = JSON.parse(JSON.parse(response.body)['message'])
    assert_equal [LeaguesController::FEHLENDE_IMPORTDATEI], fehler['errors']
    assert_equal [], fehler['warnings']
  end

  test 'fehlender Datei-Parameter antwortet ebenfalls mit 422' do
    login(@user)

    post '/api/v2/admin/leagues/import_schedule'

    assert_response :unprocessable_entity
  end

  test 'die Sitzung bleibt nach dem abgewiesenen Import bestehen' do
    login(@user)
    post '/api/v2/admin/leagues/import_schedule', params: { file: '' }
    assert_response :unprocessable_entity

    # Ein Endpunkt, der eine Cookie-Sitzung verlangt: Er antwortet nur, solange
    # die Anmeldung steht. Ohne diesen Nachweis bliebe offen, ob der 422 nicht
    # doch eine abgelaufene Sitzung verdeckt.
    get '/api/v2/admin/leagues.json'
    assert_response :success
  end

  test 'ohne Anmeldung bleibt es beim 401' do
    raw_key, = ApiKey.generate(name: 'Frontend-Test')

    # Mit Key, aber ohne Sitzung: Der Request passiert
    # `authenticate_public_request` und erreicht die Action, deren eigener
    # Anmelde-Wächter greifen muss.
    post '/api/v2/admin/leagues/import_schedule',
         params: { file: '' },
         headers: { 'X-Api-Key' => raw_key }

    assert_response :unauthorized
    assert_equal 'Nicht eingeloggt.', JSON.parse(response.body)['message']
  end

  test 'eine Datei mit falscher Endung ist ein Eingabefehler, keine Stoerung' do
    login(@user)

    hochladen(inhalt: "spalte;wert\n1;2\n", name: 'liste.csv', typ: 'text/csv')

    assert_response :unprocessable_entity
    assert_equal [LeaguesController::DATEI_NICHT_LESBAR], importfehler
  end

  test 'eine in .xlsx umbenannte Fremddatei ergibt ebenfalls 422' do
    login(@user)

    # Endung und MIME-Typ stimmen, der Inhalt ist kein Zip. Genau der Fall, den
    # die Endungspruefung von Creek durchlaesst und der erst beim Oeffnen
    # auffaellt.
    hochladen(inhalt: 'kein zip', name: 'vorlage.xlsx', typ: XLSX_MIME)

    assert_response :unprocessable_entity
    assert_equal [LeaguesController::DATEI_NICHT_LESBAR], importfehler
  end

  private

  # Die Importfehler stehen als JSON-String im Feld `message`, so wie die Maske
  # sie liest.
  def importfehler
    JSON.parse(JSON.parse(response.body)['message'])['errors']
  end

  def hochladen(inhalt:, name:, typ:)
    datei = Tempfile.new([File.basename(name, '.*'), File.extname(name)])
    datei.write(inhalt)
    datei.flush

    post '/api/v2/admin/leagues/import_schedule',
         params: { file: Rack::Test::UploadedFile.new(datei.path, typ, original_filename: name) }
  ensure
    datei&.close
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
