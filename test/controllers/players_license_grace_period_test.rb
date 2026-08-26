require 'test_helper'

# Die kostenfreie Stunde nach der Beantragung (License::GRACE_PERIOD) hat
# Geldfolgen: Innerhalb der Frist wird die Lizenz ersatzlos geloescht statt auf
# "zurueckgezogen" gesetzt, der Verein zahlt dann nichts. Hier steht, ab welchem
# Eintrag die Frist laeuft.
#
# Eigene Datei, weil players_controller_test.rb an der Zeilengrenze steht.
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

  # Der Widerruf einer Ablehnung (fe#335) schreibt einen frischen
  # `beantragt`-Eintrag. Ohne Markierung startete der die Karenzzeit neu: Der
  # Verein bekäme für einen längst kostenpflichtigen Antrag eine Gratis-Löschung,
  # und die Historie der irrtümlichen Ablehnung wäre spurlos weg.
  #
  # Der ganze Weg über die Schnittstelle, nicht nur die Auswahlmethode: Nur so
  # ist belegt, dass die Markierung beim Widerruf wirklich geschrieben wird UND
  # das Zurückziehen sie liest.
  test 'Widerruf einer Ablehnung eroeffnet keine neue Karenzzeit' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 3.days.ago.iso8601, 'created_by' => nil },
      { 'license_status_id' => License::DENIED,
        'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
    ])

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
           'der Widerruf-Eintrag muss als solcher markiert sein'

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion'],
               'nach einem Widerruf gibt es keine kostenfreie Loeschung'

    @player.reload
    assert_equal 1, @player.licenses.length, 'die Lizenz darf nicht verschwinden'
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::WITHDRAWN, last_status
    assert_equal 1, @player.licenses.first['history'].count { |h| h['license_status_id'].to_i == License::DENIED },
                 'die irrtuemliche Ablehnung bleibt als Beleg in der Historie'
  end

  # Gegenprobe zum Weg, nicht zum Statuswechsel: Der Verein beantragt ueber
  # reenable_license_request, und dieser Weg fuehrt gar nicht durch die
  # Markierungslogik von handle_license_request. Er stellt tatsaechlich neu und
  # behaelt deshalb seine Karenzzeit.
  test 'Wiedereinstellung durch den Verein behaelt die Karenzzeit' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => 3.days.ago.iso8601, 'created_by' => nil },
      { 'license_status_id' => License::WITHDRAWN,
        'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
    ])

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/reenable_license_request",
         params: { license_id: license_id },
         as: :json
    assert_response :ok

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    assert JSON.parse(response.body)['grace_period_deletion'],
           'der eigene Neuantrag bleibt innerhalb der Stunde kostenfrei'
    @player.reload
    assert_empty @player.licenses
  end

  # Welche Uebergaenge markiert werden, hielt kein Test fest: Die Bedingung liess
  # sich auf "jeder Wechsel auf beantragt" aufweiten, ohne dass die Suite es
  # merkte. Die Tabelle schliesst genau diese Naht.
  #
  # Erwartet wird die Markierung fuer JEDEN Ausgangsstatus, denn dieser Endpunkt
  # ist Admin und SBK vorbehalten: Was hier entsteht, ist immer eine
  # Verwaltungskorrektur. Der Weg aus `erteilt` heraus ist dabei der teurere -
  # dort ist die Gebuehr sicher angefallen - und er ist ueber eine veraltete
  # Zeile der Lizenzuebersicht real erreichbar.
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

  # Der teuerste Fall am ganzen Weg, und er war vorher offen: Aus `erteilt`
  # heraus schrieb der Widerruf einen unmarkierten Eintrag, der Verein konnte
  # eine erteilte Lizenz binnen einer Stunde gratis und spurlos loeschen.
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
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    @player.reload
    assert_equal 1, @player.licenses.length,
                 'eine erteilte Lizenz darf nicht gratis verschwinden'
  end

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
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    @player.reload
    assert_equal 1, @player.licenses.length
    assert_equal License::WITHDRAWN,
                 @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
  end

  # Die Frist ist exklusiv: Genau GRACE_PERIOD alt ist bereits kostenpflichtig.
  test 'genau am Ende der Karenzzeit ist das Zurueckziehen kostenpflichtig' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED,
        'created_at' => License::GRACE_PERIOD.ago.iso8601 }
    ])

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    assert_nil JSON.parse(response.body)['grace_period_deletion']
    @player.reload
    assert_equal 1, @player.licenses.length
  end
end
