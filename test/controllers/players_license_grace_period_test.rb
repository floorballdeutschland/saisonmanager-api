require 'test_helper'

# Die Karenzzeit nach der Beantragung (License::GRACE_PERIOD) hat Geldfolgen:
# Innerhalb der Frist loescht withdraw_license_request die Lizenz ersatzlos,
# statt sie auf "zurueckgezogen" zu setzen. Hier steht, welcher Eintrag die
# Frist eroeffnet - und welche nicht.
#
# Eigene Datei, weil players_controller_test.rb nahe an Metrics/ClassLength
# (Max 1000, .rubocop_todo.yml) liegt.
class PlayersLicenseGracePeriodTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license_with(history)
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'history' => history }])
    id
  end

  def withdraw(license_id)
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id }, as: :json
  end

  def rejected_weeks_ago
    license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 3.days.ago.iso8601, 'created_by' => nil },
      { 'license_status_id' => License::DENIED,
        'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
    ])
  end

  # --- Der Weg der SBK ------------------------------------------------------

  # Der Widerruf einer Ablehnung (fe#335, umgesetzt in fe#338) schreibt einen
  # frischen `beantragt`-Eintrag. Ohne Markierung startete der die Karenzzeit
  # neu: Der Verein bekaeme fuer einen laengst kostenpflichtigen Antrag eine
  # Gratis-Loeschung, und die Historie der Ablehnung waere spurlos weg.
  #
  # Der ganze Weg ueber die Schnittstelle, nicht nur die Auswahlmethode: Nur so
  # ist belegt, dass die Markierung geschrieben UND gelesen wird - dort haette
  # auch die Symbol-/String-Schluessel-Asymmetrie des Eintrags zuschlagen koennen.
  test 'Widerruf einer Ablehnung eroeffnet keine neue Karenzzeit' do
    license_id = rejected_weeks_ago

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::REQUESTED,
                   reason: 'Ablehnung widerrufen (versehentliche Ablehnung)' },
         as: :json
    assert_response :ok

    @player.reload
    revoke_entry = @player.licenses.first['history'].max_by { |h| h['created_at'] }
    assert_equal License::REQUESTED, revoke_entry['license_status_id'].to_i
    assert revoke_entry[License::REVOKED_REJECTION_KEY],
           'der Widerruf-Eintrag muss als Korrektur markiert sein'

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion'],
               'nach einer Korrektur gibt es keine kostenfreie Loeschung'

    @player.reload
    assert_equal 1, @player.licenses.length, 'die Lizenz darf nicht verschwinden'
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::WITHDRAWN, last_status
    assert_equal 1, @player.licenses.first['history'].count { |h| h['license_status_id'].to_i == License::DENIED },
                 'die irrtuemliche Ablehnung bleibt als Beleg in der Historie'
  end

  # Welche Uebergaenge markiert werden, hielt zuerst kein Test fest: Die
  # Bedingung liess sich auf "jeder Wechsel auf beantragt" aufweiten, ohne dass
  # die Suite es merkte. Die Tabelle schliesst genau diese Naht.
  #
  # Erwartet wird die Markierung fuer JEDEN Ausgangsstatus, denn dieser Endpunkt
  # ist Admin und SBK vorbehalten: Was hier entsteht, ist immer eine
  # Verwaltungskorrektur, nie eine Beantragung.
  {
    'abgelehnt' => License::DENIED,
    'erteilt' => License::APPROVED,
    'zurueckgezogen' => License::WITHDRAWN,
    'ungueltig wg. Transfer' => License::TRANSFER
  }.each do |label, from_status|
    test "Wechsel von #{label} auf beantragt wird als Korrektur markiert" do
      license_id = license_with([
        { 'license_status_id' => License::REQUESTED,
          'created_at' => 3.days.ago.iso8601 },
        { 'license_status_id' => from_status,
          'created_at' => 2.days.ago.iso8601 }
      ])

      login_as(create(:user, :admin))
      post "/api/v2/admin/players/#{@player.id}/handle_license_request",
           params: { license_id: license_id, license_status_id: License::REQUESTED },
           as: :json
      assert_response :ok

      @player.reload
      entry = @player.licenses.first['history'].max_by { |h| h['created_at'] }
      assert entry[License::REVOKED_REJECTION_KEY],
             "#{label} -> beantragt muss markiert sein, sonst startet die Karenzzeit neu"
    end
  end

  # Der teuerste Fall, und er war im ersten Anlauf dieses Fixes offen: Aus
  # `erteilt` heraus schrieb der Widerruf einen unmarkierten Eintrag, dort ist
  # die Gebuehr am sichersten angefallen.
  test 'Widerruf einer Erteilung eroeffnet keine neue Karenzzeit' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 3.days.ago.iso8601 },
      { 'license_status_id' => License::APPROVED,
        'created_at' => 2.days.ago.iso8601 }
    ])

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::REQUESTED },
         as: :json
    assert_response :ok

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    @player.reload
    assert_equal 1, @player.licenses.length,
                 'eine erteilte Lizenz darf nicht gratis verschwinden'
  end

  # --- Der Weg des Vereins --------------------------------------------------

  # Auch der Verein bekommt kein zweites Gratis-Fenster: Er hat fuer diese Lizenz
  # laengst einmal beantragt, und genau dieser erste Antrag hatte seine
  # Karenzzeit. Sonst waeren zwei Klicks - wieder einstellen, dann kostenfrei
  # loeschen - ein Weg, eine abgelehnte und damit kostenpflichtige Lizenz spurlos
  # zu entfernen, ganz ohne SBK.
  test 'Wiedereinstellung durch den Verein eroeffnet keine neue Karenzzeit' do
    license_id = rejected_weeks_ago

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/reenable_license_request",
         params: { license_id: license_id }, as: :json
    assert_response :ok

    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion'],
               'zwei Klicks duerfen keine gebuehrenpflichtige Lizenz aufloesen'
    @player.reload
    assert_equal 1, @player.licenses.length
    assert_equal 1, @player.licenses.first['history'].count { |h| h['license_status_id'].to_i == License::DENIED },
                 'die Ablehnung bleibt als Beleg in der Historie'
  end

  # Der Erstantrag ist der einzige Weg, der die Karenzzeit eroeffnet - sonst
  # waere die Regel keine Ausnahme mehr, sondern die Abschaffung des Fensters.
  test 'der Erstantrag des Vereins behaelt seine Karenzzeit' do
    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id }, as: :json
    assert_response :ok

    license_id = @player.reload.licenses.first['id']
    withdraw(license_id)

    assert_response :ok
    assert JSON.parse(response.body)['grace_period_deletion'],
           'der frische Erstantrag bleibt innerhalb der Frist kostenfrei'
    assert_empty @player.reload.licenses
  end

  # --- Ablauf einer Sperre --------------------------------------------------

  # lift_suspension! schreibt den vorherigen Status zurueck. War das `beantragt`,
  # entstand ein frischer Eintrag, obwohl niemand neu beantragt hat: die Sperre
  # ist bloss abgelaufen.
  #
  # Ueber die echten Methoden, nicht von Hand: Ein gebautes Fixture koennte einen
  # Zustand erzeugen, den die Sperrlogik so nie hinterlaesst.
  test 'Ablauf einer Sperre eroeffnet keine neue Karenzzeit' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 10.days.ago.iso8601 }
    ])
    suspension = @player.suspend!(valid_until: 1.day.ago.to_date, user_id: nil,
                                  valid_from: 5.days.ago.to_date, reason: 'Test')
    assert_equal License::SUSPENDED,
                 @player.reload.licenses.first['history']
                        .max_by { |h| h['created_at'] }['license_status_id'].to_i

    @player.lift_suspension!(suspension, user_id: nil)

    @player.reload
    restored = @player.licenses.first['history'].max_by { |h| h['created_at'] }
    assert_equal License::REQUESTED, restored['license_status_id'].to_i
    assert restored[License::REVOKED_REJECTION_KEY],
           'der zurueckgeschriebene Status ist keine neue Beantragung'

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    assert_equal 1, @player.reload.licenses.length
  end

  # --- Grenzfaelle ----------------------------------------------------------

  # Bleibt kein unmarkierter Antrag uebrig, liefert der Anker nil. Dass der
  # Aufrufer daraus "kostenpflichtig" macht und nicht "kostenfrei", war
  # ungeschuetzt: Die Umkehrung der Bedingung lief gruen durch.
  test 'ohne verwertbaren Antrag bleibt das Zurueckziehen kostenpflichtig' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 1.minute.ago.iso8601,
        License::REVOKED_REJECTION_KEY => true }
    ])

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    @player.reload
    assert_equal 1, @player.licenses.length
    assert_equal License::WITHDRAWN,
                 @player.licenses.first['history']
                        .max_by { |h| h['created_at'] }['license_status_id'].to_i
  end

  # Die Markierung gehoert nur an `beantragt`-Eintraege. An einem
  # `zurueckgezogen`-Eintrag waere sie fuer die Frist folgenlos - der Anker sieht
  # nur beantragt -, aber ein Fremdschluessel in der Historie, den niemand liest.
  test 'ein zurueckgezogen-Eintrag traegt keine Markierung' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 2.hours.ago.iso8601 }
    ])

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)
    assert_response :ok

    entry = @player.reload.licenses.first['history'].max_by { |h| h['created_at'] }
    assert_equal License::WITHDRAWN, entry['license_status_id'].to_i
    assert_nil entry[License::REVOKED_REJECTION_KEY]
  end

  # Die Frist ist exklusiv: Genau GRACE_PERIOD alt ist bereits kostenpflichtig.
  test 'genau am Ende der Karenzzeit ist das Zurueckziehen kostenpflichtig' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => License::GRACE_PERIOD.ago.iso8601 }
    ])

    login_as(create(:user, :vm, club_id: @club.id))
    withdraw(license_id)

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    assert_equal 1, @player.reload.licenses.length
  end
end
