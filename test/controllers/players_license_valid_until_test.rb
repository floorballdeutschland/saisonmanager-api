require 'test_helper'

# Gueltigkeit der erteilten Lizenz. `valid_until` wird bei der Genehmigung nach
# players.licenses geschrieben und war bis api#459 nirgends geprueft: Zwei
# Mutationen (immer Kalenderjahr; Datum um fuenf Jahre verschoben) liessen die
# komplette Suite gruen.
#
# Das Saisonjahr wird aus dem Saisonnamen gelesen, und der ist Freitext aus der
# Verwaltung. `split('/').first` verlangte, dass der Name mit den Ziffern beginnt:
# bei „Saison 2026/27" ergab `'Saison 2026'.to_i` eine 0, die Gueltigkeit fiel
# still aufs Kalenderjahr, und die Lizenz war im Genehmigungsmoment schon
# abgelaufen. Genau diese Schreibweise ist der Standardwert der Setting-Factory.
class PlayersLicenseValidUntilTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }])
    login_as(create(:user, :admin))
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def request_license_for(season_id)
    license_id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => license_id, 'team_id' => @team.id, 'season_id' => season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'history' => [{ 'license_status_id' => License::REQUESTED,
                                                 'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }])
    license_id
  end

  def approve_and_read_valid_until(season_id, params = {})
    license_id = request_license_for(season_id)
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED }.merge(params), as: :json
    assert_response :ok
    @player.reload.licenses.first['valid_until'].to_s[0, 10]
  end

  # Die kommende Saison, nicht die laufende: Nur dort unterscheidet sich ein
  # korrekt gelesenes Saisonjahr vom Kalenderjahr-Fallback. Mit der laufenden
  # Saison faellt beides zusammen und der Test waere tautologisch.
  test 'valid_until folgt dem Saisonjahr, in allen Schreibweisen des Namens' do
    @team.update!(league: create(:league, game_operation: @game_operation, season_id: '19'))

    {
      '2027/2028' => '2028-07-31',
      '2027/28' => '2028-07-31',
      'Saison 2027/28' => '2028-07-31',
      'Saison 2027/2028' => '2028-07-31'
    }.each do |name, expected|
      create(:setting, current_season_id: '18', seasons: { '19' => { 'name' => name } })
      assert_equal expected, approve_and_read_valid_until('19'),
                   "Schreibweise #{name.inspect} muss dasselbe Saisonjahr ergeben"
    end
  end

  # Auch die blanke String-Form muss gelesen werden, sonst greift der Fallback.
  test 'valid_until folgt dem Saisonjahr auch bei blankem String unter der Saison' do
    @team.update!(league: create(:league, game_operation: @game_operation, season_id: '19'))
    create(:setting, current_season_id: '18', seasons: { '19' => '2027/2028' })

    assert_equal '2028-07-31', approve_and_read_valid_until('19')
  end

  # Ohne lesbares Jahr bleibt es beim Kalenderjahr, damit eine Fehlkonfiguration
  # im Saisonnamen die Lizenzerteilung nicht blockiert. Das Signal darueber geht
  # nach Sentry, nicht an den Antragsteller.
  test 'valid_until faellt ohne Saisonjahr auf das Kalenderjahr zurueck' do
    create(:setting, current_season_id: '18', seasons: { '18' => { 'name' => 'Saison 26/27' } })

    assert_equal "#{Date.current.year}-07-31", approve_and_read_valid_until('18')
  end

  test 'ein ausdruecklich mitgegebenes valid_until hat Vorrang' do
    assert_equal '2099-01-01', approve_and_read_valid_until(@league.season_id, valid_until: '2099-01-01')
  end
end
