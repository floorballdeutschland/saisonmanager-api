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

  # Gegenprobe: Die Markierung haengt am Widerruf einer ABLEHNUNG, nicht an jedem
  # Wechsel auf `beantragt`. Stellt der Verein einen zurueckgezogenen Antrag
  # wieder ein, stellt er tatsaechlich neu und behaelt seine Karenzzeit.
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
end
