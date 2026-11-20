require 'test_helper'

# Ein zurückgezogener Antrag bleibt nach der Karenzzeit als Eintrag stehen. Der
# Verein kann ihn danach nur wieder einstellen (reenable_license_request), nicht
# neu beantragen. Wer beim ersten Antrag den Express-Haken vergessen und deshalb
# zurückgezogen hatte, kam bisher nicht mehr zur Expresslizenz.
class PlayersReenableExpressTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @vm = create(:user, :vm, club_id: @club.id)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def team_with_express(enabled: true)
    sa = create(:state_association, express_license_enabled: enabled, sbk_email: 'sbk@example.de')
    league = create(:league, :current_season,
                    game_operation: create(:game_operation, state_association_id: sa.id))
    create(:game_day, league: league, date: (Date.current + 1).to_s)
    create(:team, league: league, club: @club)
  end

  def license_for(team, last_status)
    id = Digest::UUID.uuid_v4
    history = [{ 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601, 'created_by' => nil }]
    history << { 'license_status_id' => last_status, 'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
    @player.update!(licenses: [{ 'id' => id, 'team_id' => team.id, 'season_id' => team.league.season_id,
                                 'league_class_id' => team.league.league_class_id, 'express' => false,
                                 'history' => history }])
    id
  end

  def reenable(license_id, express:)
    post "/api/v2/user/players/#{@player.id}/reenable_license_request",
         params: { license_id: license_id, express: express }, as: :json
  end

  def stored_license
    @player.reload.licenses.first
  end

  test 'zurueckgezogener Antrag laesst sich als Expresslizenz wieder einstellen' do
    team = team_with_express
    license_id = license_for(team, License::WITHDRAWN)
    login_as(@vm)

    assert_enqueued_emails 1 do
      reenable(license_id, express: true)
      assert_response :ok
    end

    license = stored_license
    assert license['express']
    entry = license['history'].last
    assert_equal License::REQUESTED, entry['license_status_id'].to_i
    assert entry[License::EXPRESS_REQUESTED_KEY]

    perform_enqueued_jobs
    assert_equal ['sbk@example.de'], ActionMailer::Base.deliveries.last.to
  end

  test 'abgelehnter Antrag laesst sich ebenfalls als Expresslizenz wieder einstellen' do
    team = team_with_express
    license_id = license_for(team, License::DENIED)
    login_as(@vm)

    reenable(license_id, express: true)

    assert_response :ok
    assert stored_license['express']
  end

  # Gegenprobe: Ohne Haken bleibt das Wiedereinstellen, wie es war.
  test 'ohne Express bleibt das Wiedereinstellen unveraendert und ohne Mail' do
    team = team_with_express
    license_id = license_for(team, License::WITHDRAWN)
    login_as(@vm)

    assert_enqueued_emails 0 do
      reenable(license_id, express: false)
      assert_response :ok
    end

    license = stored_license
    assert_not license['express']
    assert_nil license['history'].last[License::EXPRESS_REQUESTED_KEY]
    assert_equal License::REQUESTED, license['history'].last['license_status_id'].to_i
  end

  test 'ohne Expressmoeglichkeit der Mannschaft gibt es eine Absage und keine Aenderung' do
    team = team_with_express(enabled: false)
    license_id = license_for(team, License::WITHDRAWN)
    login_as(@vm)

    assert_enqueued_emails 0 do
      reenable(license_id, express: true)
      assert_response :unprocessable_entity
    end

    license = stored_license
    assert_not license['express']
    assert_equal License::WITHDRAWN, License.current_status_id(license)
  end

  test 'ein laufender Antrag wird ueber das Wiedereinstellen nicht zur Expresslizenz' do
    team = team_with_express
    license_id = license_for(team, License::REQUESTED)
    login_as(@vm)

    reenable(license_id, express: true)

    assert_response :unprocessable_entity
    assert_not stored_license['express']
  end

  test 'eine schon einmal erteilte Lizenz wird nicht nachtraeglich zur Expresslizenz' do
    team = team_with_express
    license_id = license_for(team, License::APPROVED)
    @player.licenses.first['history'] << { 'license_status_id' => License::DENIED,
                                            'created_at' => 1.day.ago.iso8601, 'created_by' => nil }
    @player.save!
    login_as(@vm)

    reenable(license_id, express: true)

    assert_response :unprocessable_entity
    assert_not stored_license['express']
  end

  # Mit einer Mannschaft OHNE Expressmoeglichkeit: Stuende die Rechtepruefung
  # hinter den Absagen, kaeme hier 422 statt 403.
  test 'fremder Verein bekommt keine Auskunft ueber die Expressmoeglichkeit' do
    team = team_with_express(enabled: false)
    license_id = license_for(team, License::WITHDRAWN)
    login_as(create(:user, :vm, club_id: create(:club).id))

    reenable(license_id, express: true)

    assert_response :forbidden
    assert_not stored_license['express']
  end

  test 'ein Antrag, der schon Express war, loest keine zweite Mail aus' do
    team = team_with_express
    license_id = license_for(team, License::DENIED)
    @player.licenses.first['express'] = true
    @player.save!
    login_as(@vm)

    assert_enqueued_emails 0 do
      reenable(license_id, express: true)
      assert_response :unprocessable_entity
    end
  end

  # Mehrfach vergebene id (Altbestand nach Zusammenfuehrungen): Geschrieben wird
  # in jeden Eintrag mit der id, der Zuschlag traefe auch die erteilte Lizenz.
  test 'eine mehrfach vergebene Lizenz-id wird nicht zur Expresslizenz' do
    team = team_with_express
    license_id = license_for(team, License::WITHDRAWN)
    old = @player.licenses.first.deep_dup
    old['season_id'] = '15'
    old['history'] = [{ 'license_status_id' => License::APPROVED, 'created_at' => 2.years.ago.iso8601,
                        'created_by' => nil }]
    @player.update!(licenses: @player.licenses + [old])
    login_as(@vm)

    reenable(license_id, express: true)

    assert_response :unprocessable_entity
    assert(@player.reload.licenses.none? { |l| l['express'] })
  end

  test 'gesperrter Spieler wird nicht als Expresslizenz wieder eingestellt' do
    team = team_with_express
    license_id = license_for(team, License::WITHDRAWN)
    PlayerSuspension.create!(player: @player, team_id: team.id,
                             valid_from: Date.current - 1, valid_until: Date.current + 30)
    login_as(@vm)

    assert_enqueued_emails 0 do
      reenable(license_id, express: true)
      assert_response :unprocessable_entity
    end
  end

  test 'Altbestand mit _id laesst sich als Expresslizenz wieder einstellen' do
    team = team_with_express
    license_id = license_for(team, License::WITHDRAWN)
    legacy = @player.licenses.first
    legacy['_id'] = legacy.delete('id')
    @player.update!(licenses: [legacy])
    login_as(@vm)

    reenable(license_id, express: true)

    assert_response :ok
    assert stored_license['express']
  end
end
