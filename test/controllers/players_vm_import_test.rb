require 'test_helper'

# CSV-Nachtrag fehlender Stammdaten in der Vereinssicht („Meine Spieler*innen").
# Der Verein exportiert seinen Bestand, fuellt die Luecken in Excel und laedt
# dieselbe Datei wieder hoch.
#
# Die beiden Zusagen, an denen der Import haengt: Es wird NUR dort geschrieben,
# wo im Profil nichts steht, und die Feldrechte sind dieselben wie in der Maske
# daneben (Adresse: Verein, uebrige Stammdaten: Admin/SBK). Beide sind hier
# einzeln geprueft — ein Import, der einen gepflegten Wert ueberschreibt, faellt
# niemandem auf, weil der alte Wert dabei spurlos verschwindet.
class PlayersVmImportTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, :current_season, game_operation: @go)
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club)
    @ohne_adresse = create(:player, email: nil, first_name: 'Lea', last_name: 'Ohne',
                                    clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    @mit_adresse = create(:player, email: 'gepflegt@example.org', first_name: 'Tim', last_name: 'Mit',
                                   clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
  end

  test 'der Verein traegt eine fehlende Adresse nach' do
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;E-Mail\n#{@ohne_adresse.id};neu@example.org\n")

    assert_equal 1, report['total_rows']
    assert_equal 1, report['updated'].size
    assert_equal @ohne_adresse.id, report['updated'].first['id']
    assert_equal 'neu@example.org', report['updated'].first['fields']['email']
    assert_equal 'neu@example.org', @ohne_adresse.reload.email
  end

  # Die Kernzusage. Ohne sie waere ein alter Vereinsexport ein Werkzeug zum
  # stillen Zurueckdrehen gepflegter Adressen.
  test 'eine gepflegte Adresse wird nicht ueberschrieben' do
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;E-Mail\n#{@mit_adresse.id};anders@example.org\n")

    assert_empty report['updated']
    assert_equal 1, report['skipped'].size
    assert_equal 'already_set', report['skipped'].first['reasons']['email']
    assert_equal 'gepflegt@example.org', @mit_adresse.reload.email
  end

  # Derselbe Wert ist kein Konflikt: Wer die Export-Datei unveraendert wieder
  # hochlaedt (oder zweimal hintereinander), soll keine Konfliktmeldung ueber
  # seinen ganzen Bestand bekommen.
  test 'ein identischer Wert wird als identisch gemeldet, nicht als Konflikt' do
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;E-Mail\n#{@mit_adresse.id};GEPFLEGT@example.org\n")

    assert_equal 'identical', report['skipped'].first['reasons']['email']
  end

  # Geburtsdatum, Geschlecht und Nationalitaet aendert der Verein nur ueber den
  # Aenderungsantrag. Der Import darf dieser Trennung keine Hintertuer geben,
  # auch nicht fuer ein leeres Feld.
  test 'der Verein traegt keine uebrigen Stammdaten nach' do
    ohne_geburtsdatum = create(:player, birthdate: nil, email: nil,
                                        clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;Geburtsdatum;E-Mail\n#{ohne_geburtsdatum.id};01.02.2010;neu@example.org\n")

    # Die Adresse geht durch, das Geburtsdatum nicht — und der Report benennt
    # das, statt die Spalte stillschweigend zu verwerfen.
    assert_equal 1, report['updated'].size
    assert_equal 'no_permission', report['updated'].first['skipped']['birthdate']
    ohne_geburtsdatum.reload
    assert_nil ohne_geburtsdatum.birthdate
    assert_equal 'neu@example.org', ohne_geburtsdatum.email
  end

  test 'die SBK traegt fehlendes Geburtsdatum und Geschlecht nach' do
    lueckenhaft = create(:player, birthdate: nil, gender: nil, email: nil,
                                  clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    report = import_csv("ID;Geburtsdatum;Geschlecht\n#{lueckenhaft.id};01.02.2010;w\n")

    assert_equal 1, report['updated'].size
    lueckenhaft.reload
    assert_equal Date.new(2010, 2, 1), lueckenhaft.birthdate
    assert_equal 'W', lueckenhaft.gender
  end

  test 'ISO-Datum wird ebenso gelesen wie das deutsche Format' do
    lueckenhaft = create(:player, birthdate: nil,
                                  clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    import_csv("ID;Geburtsdatum\n#{lueckenhaft.id};2010-02-01\n")

    assert_equal Date.new(2010, 2, 1), lueckenhaft.reload.birthdate
  end

  # Eine Zeile mit unbrauchbarem Wert wird ganz verworfen, auch in ihren
  # gueltigen Feldern: Ein halb angewandter Datensatz waere fuer den Verein
  # nicht von einem vollstaendigen zu unterscheiden.
  test 'eine ungueltige Adresse schreibt in dieser Zeile nichts' do
    ohne_alles = create(:player, birthdate: nil, email: nil,
                                 clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    report = import_csv("ID;E-Mail;Geburtsdatum\n#{ohne_alles.id};keine-adresse;01.02.2010\n")

    assert_empty report['updated']
    assert_equal 1, report['invalid'].size
    assert_match 'E-Mail-Adresse ist ung', report['invalid'].first['reason']
    ohne_alles.reload
    assert_nil ohne_alles.email
    assert_nil ohne_alles.birthdate
  end

  test 'ein Geburtsdatum in der Zukunft wird abgewiesen' do
    lueckenhaft = create(:player, birthdate: nil,
                                  clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    report = import_csv("ID;Geburtsdatum\n#{lueckenhaft.id};#{1.year.from_now.strftime('%d.%m.%Y')}\n")

    assert_equal 1, report['invalid'].size
    assert_nil lueckenhaft.reload.birthdate
  end

  # Der Schluessel ist die ID, und sie wird gegen den Bestand DIESES Vereins
  # geprueft. Eine fremde ID in der Datei (kopierte Zeile, falscher Export) darf
  # kein Schreibrecht auf ein beliebiges Profil verschaffen.
  test 'eine ID aus einem anderen Verein wird nicht geschrieben' do
    fremd = create(:player, email: nil, clubs: [{ 'club_id' => create(:club).id, 'home_club' => true }])
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;E-Mail\n#{fremd.id};neu@example.org\n")

    assert_equal 1, report['not_found'].size
    assert_equal fremd.id, report['not_found'].first['id']
    assert_nil fremd.reload.email
  end

  test 'eine ID, die keine Zahl ist, landet als unbrauchbar im Report' do
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("ID;E-Mail\nkeine-id;neu@example.org\n")

    assert_equal 1, report['invalid'].size
    assert_equal 'ID ist keine Zahl', report['invalid'].first['reason']
  end

  # Die vier Toepfe muessen total_rows ergeben, sonst rechnet der Report des
  # Frontends eine Zahl aus, die es nicht gibt.
  test 'jede Datenzeile landet in genau einem Topf' do
    login(create(:user, :vm, club_id: @club.id))

    csv = "ID;E-Mail\n" \
          "#{@ohne_adresse.id};neu@example.org\n" \
          "#{@mit_adresse.id};anders@example.org\n" \
          "999999;irgendwas@example.org\n" \
          "keine-id;x@example.org\n"
    report = import_csv(csv)

    summe = %w[updated skipped not_found invalid].sum { |topf| report[topf].size }
    assert_equal report['total_rows'], summe
    assert_equal 4, report['total_rows']
  end

  # Der eigene Export schreibt UTF-8 mit BOM und CRLF; deutsches Excel gibt das
  # so zurueck. Ohne diese Normalisierung waere die erste Spaltenueberschrift
  # „﻿ID" und die Datei „ohne Spalte ID".
  test 'die eigene Export-Datei mit BOM und CRLF wird gelesen' do
    login(create(:user, :vm, club_id: @club.id))

    report = import_csv("﻿\"ID\";\"E-Mail\"\r\n\"#{@ohne_adresse.id}\";\"neu@example.org\"\r\n")

    assert_equal 1, report['updated'].size
    assert_equal 'neu@example.org', @ohne_adresse.reload.email
  end

  test 'eine Datei ohne ID-Spalte wird abgewiesen' do
    login(create(:user, :vm, club_id: @club.id))

    post '/api/v2/admin/vm/players/import',
         params: { club_id: @club.id, file: csv_upload("Nachname;E-Mail\nOhne;neu@example.org\n") }

    assert_response :unprocessable_entity
    assert_match 'Spalte "ID"', JSON.parse(response.body)['message']
  end

  test 'eine Datei ohne nachtragbare Spalte wird abgewiesen' do
    login(create(:user, :vm, club_id: @club.id))

    post '/api/v2/admin/vm/players/import',
         params: { club_id: @club.id, file: csv_upload("ID;Nachname\n#{@ohne_adresse.id};Ohne\n") }

    assert_response :unprocessable_entity
    assert_match 'keine Spalte mit nachtragbaren Angaben', JSON.parse(response.body)['message']
  end

  test 'ohne Datei antwortet der Endpunkt mit 422' do
    login(create(:user, :vm, club_id: @club.id))

    post '/api/v2/admin/vm/players/import', params: { club_id: @club.id }

    assert_response :unprocessable_entity
  end

  # Der Zugang haengt an derselben Pruefung wie die Liste selbst.
  test 'ein fremder Verein wird abgewiesen' do
    login(create(:user, :vm, club_id: create(:club).id))

    post '/api/v2/admin/vm/players/import',
         params: { club_id: @club.id, file: csv_upload("ID;E-Mail\n#{@ohne_adresse.id};neu@example.org\n") }

    assert_response :forbidden
    assert_nil @ohne_adresse.reload.email
  end

  test 'ohne club_id antwortet der Endpunkt mit 400' do
    login(create(:user, :vm, club_id: @club.id))

    post '/api/v2/admin/vm/players/import',
         params: { file: csv_upload("ID;E-Mail\n#{@ohne_adresse.id};neu@example.org\n") }

    assert_response :bad_request
  end

  # Der Export braucht die Nationalitaet in der Liste, sonst kaeme die Spalte
  # leer zurueck und der Verein hielte sie fuer ungepflegt.
  test 'die Vereinsliste nennt die Nationalitaet' do
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/vm/players?club_id=#{@club.id}"
    assert_response :success
    zeile = JSON.parse(response.body).find { |p| p['id'] == @ohne_adresse.id }
    assert_equal @ohne_adresse.nation_id, zeile['nation_id']
    assert zeile.key?('nation_string')
  end

  private

  def import_csv(content)
    post '/api/v2/admin/vm/players/import',
         params: { club_id: @club.id, file: csv_upload(content) }
    assert_response :success
    JSON.parse(response.body)
  end

  def csv_upload(content)
    file = Tempfile.new(['spieler', '.csv'])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'text/csv', original_filename: 'spieler.csv')
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
