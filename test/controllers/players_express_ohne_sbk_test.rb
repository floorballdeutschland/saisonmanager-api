require 'test_helper'

# Die Expresslizenz ist im Kern die sofortige Benachrichtigung der zuständigen
# SBK und kostet den Verein nach Gebührenordnung extra. Fehlt am Landesverband
# eine erreichbare SBK-Adresse, brach PlayerMailer#express_license_requested
# still ab (`return if sbk_email.blank?`) — die Lizenz wurde aber trotzdem als
# Express-Antrag gespeichert. Der Verein bezahlte damit eine Eilbearbeitung, von
# der niemand erfuhr.
class PlayersExpressOhneSbkTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def league_with(sbk_email:, parent: nil)
    sa = create(:state_association, express_license_enabled: true, sbk_email: sbk_email, parent: parent)
    league = create(:league, :current_season,
                    game_operation: create(:game_operation, state_association_id: sa.id))
    create(:game_day, league: league, date: (Date.current + 1).to_s)
    league
  end

  def player_of_club
    create(:player,
           clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }])
  end

  test 'ohne erreichbare SBK entsteht keine Express-Lizenz und keine Mail' do
    team = create(:team, league: league_with(sbk_email: nil), club: @club)
    player = player_of_club
    login_as(@vm)

    assert_enqueued_emails 0 do
      post "/api/v2/user/players/#{player.id}/request_license",
           params: { team_id: team.id, express: true }, as: :json
      assert_response :ok
    end

    assert_not player.reload.licenses.first['express'],
               'die Lizenz darf nicht als bezahlte Eilbearbeitung gelten, wenn niemand sie erhält'
  end

  test 'das Antragsformular bietet die Expresslizenz ohne SBK gar nicht an' do
    team = create(:team, league: league_with(sbk_email: nil), club: @club)
    login_as(@vm)

    get "/api/v2/user/team/#{team.id}/licenses"

    assert_response :success
    assert_not JSON.parse(response.body)['express_license_enabled']
  end

  # Gegenprobe: Mit Adresse bleibt alles wie bisher.
  test 'mit erreichbarer SBK bleibt die Expresslizenz moeglich' do
    team = create(:team, league: league_with(sbk_email: 'sbk@example.de'), club: @club)
    player = player_of_club
    login_as(@vm)

    get "/api/v2/user/team/#{team.id}/licenses"
    assert JSON.parse(response.body)['express_license_enabled']

    assert_enqueued_emails 1 do
      post "/api/v2/user/players/#{player.id}/request_license",
           params: { team_id: team.id, express: true }, as: :json
      assert_response :ok
    end

    perform_enqueued_jobs
    assert_equal ['sbk@example.de'], ActionMailer::Base.deliveries.last.to
    assert player.reload.licenses.first['express']
  end

  # Ein untergeordneter Landesverband pflegt oft kein eigenes Postfach. Über den
  # Verbund ist er erreichbar, die Expresslizenz muss dort weiter gehen — sonst
  # fiele sie für die drei LV der SBK Ost aus.
  test 'die Adresse des Verbunds genuegt' do
    parent = create(:state_association, sbk_email: 'dach-sbk@example.de')
    team = create(:team, league: league_with(sbk_email: nil, parent: parent), club: @club)
    player = player_of_club
    login_as(@vm)

    assert_enqueued_emails 1 do
      post "/api/v2/user/players/#{player.id}/request_license",
           params: { team_id: team.id, express: true }, as: :json
      assert_response :ok
    end

    perform_enqueued_jobs
    assert_equal ['dach-sbk@example.de'], ActionMailer::Base.deliveries.last.to
    assert player.reload.licenses.first['express']
  end
end
