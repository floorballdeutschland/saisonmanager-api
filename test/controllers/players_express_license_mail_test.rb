require 'test_helper'

# Benachrichtigung der SBK über einen Expresslizenz-Antrag. Zuständig ist der
# Verband des Spielbetriebs der Liga, die die Expresslizenz erlaubt – und eine
# Mannschaft spielt über team.leagues auch in Pokal-Ligen fremder Verbände (#455).
# Die Expresslizenz kostet extra, deshalb entscheidet diese Liga auch darüber,
# welcher Verband die Zusatzkosten stellt.
class PlayersExpressLicenseMailTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # Liga, deren Verband die Expresslizenz erlaubt und deren erster Spieltag im
  # Fenster liegt. Beides muss zusammenkommen, sonst ist
  # League#express_license_possible? unabhängig von der Auswahl schon false.
  def express_league(sbk_email:, name:, season_id: '18', days_ahead: 1, express: true)
    sa = create(:state_association, sbk_email: sbk_email, express_license_enabled: express)
    league = create(:league, name: name, season_id: season_id,
                             game_operation: create(:game_operation, state_association_id: sa.id))
    create(:game_day, league: league, date: (Date.current + days_ahead).to_s)
    league
  end

  def player_of_club
    create(:player,
           clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }])
  end

  # Erlaubt nur die Pokal-Liga die Expresslizenz, gehört der Antrag zu deren
  # Verband. Die Hauptliga erlaubt sie hier gar nicht, ihre SBK hätte mit dem
  # Antrag nichts zu tun.
  test 'Expresslizenz-Antrag geht an die SBK der Liga, die sie erlaubt' do
    haupt = express_league(sbk_email: 'haupt-sbk@example.de', name: 'Regionalliga Bayern', express: false)
    pokal = express_league(sbk_email: 'pokal-sbk@example.de', name: 'FD-Pokal')
    team = create(:team, league: haupt, club: @club)
    team.update!(cup_leagues: [pokal.id])
    player = player_of_club
    login_as(@vm)

    assert_enqueued_emails 1 do
      post "/api/v2/user/players/#{player.id}/request_license",
           params: { team_id: team.id, express: true }, as: :json
      assert_response :ok
    end

    perform_enqueued_jobs
    assert_equal ['pokal-sbk@example.de'], ActionMailer::Base.deliveries.last.to
    assert player.reload.licenses.first['express']
  end

  # Erlauben beide Ligen die Expresslizenz, gehört der Antrag zur Hauptliga.
  # Vorher entschied das die Sortierung des default_scope von League: der
  # kleinere Spielbetrieb stellte die Pokal-Liga nach vorn, und die Mail landete
  # samt Zusatzkosten bei einem Verband, den der Verein im Formular nie gesehen hat.
  test 'bei zwei erlaubenden Ligen geht der Antrag an die SBK der Hauptliga' do
    pokal = express_league(sbk_email: 'pokal-sbk@example.de', name: 'FD-Pokal')
    haupt = express_league(sbk_email: 'haupt-sbk@example.de', name: 'Regionalliga Bayern')
    team = create(:team, league: haupt, club: @club)
    team.update!(cup_leagues: [pokal.id])
    assert_equal pokal.id, team.reload.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Pokal-Liga nach vorn'
    player = player_of_club
    login_as(@vm)

    post "/api/v2/user/players/#{player.id}/request_license",
         params: { team_id: team.id, express: true }, as: :json
    assert_response :ok

    perform_enqueued_jobs
    assert_equal ['haupt-sbk@example.de'], ActionMailer::Base.deliveries.last.to
  end

  # Der default_scope sortiert zuerst nach season_id. Ein liegengebliebener
  # Eintrag in cup_leagues aus einer vergangenen Saison gewann damit selbst gegen
  # die Hauptliga der laufenden – der Antrag ging an einen Verband, mit dem die
  # Mannschaft in dieser Saison nichts mehr zu tun hat.
  test 'ein Alt-Eintrag in cup_leagues zieht den Antrag nicht mehr zu sich' do
    alt = express_league(sbk_email: 'alt-sbk@example.de', name: 'Alt-Pokal', season_id: '17')
    haupt = express_league(sbk_email: 'haupt-sbk@example.de', name: 'Regionalliga Bayern')
    team = create(:team, league: haupt, club: @club)
    team.update!(cup_leagues: [alt.id])
    assert_equal alt.id, team.reload.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Alt-Saison nach vorn'
    player = player_of_club
    login_as(@vm)

    post "/api/v2/user/players/#{player.id}/request_license",
         params: { team_id: team.id, express: true }, as: :json
    assert_response :ok

    perform_enqueued_jobs
    assert_equal ['haupt-sbk@example.de'], ActionMailer::Base.deliveries.last.to
  end

  # Erlaubt keine Liga der Mannschaft die Expresslizenz, geht nichts heraus und
  # die Lizenz wird auch nicht als Express-Antrag vermerkt.
  test 'ohne erlaubende Liga verschickt der Antrag keine Expresslizenz-Mail' do
    haupt = express_league(sbk_email: 'haupt-sbk@example.de', name: 'Regionalliga Bayern', express: false)
    team = create(:team, league: haupt, club: @club)
    player = player_of_club
    login_as(@vm)

    assert_enqueued_emails 0 do
      post "/api/v2/user/players/#{player.id}/request_license",
           params: { team_id: team.id, express: true }, as: :json
      assert_response :ok
    end
    assert_not player.reload.licenses.first['express']
  end
end
