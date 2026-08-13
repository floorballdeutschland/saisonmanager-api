require 'test_helper'

# Weg 3 (#403): Wo ein Landesverband die Ansetzung außerhalb der SBK erlaubt, aber
# nicht auf Personenebene, pflegt die RSK dieselbe Spieleliste in einem reduzierten
# Modus – Verein aus der Liga wählen oder Freitext eintragen.
module Admin
  class RefereeAssignmentClubModeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      create(:setting)
      # Hauptschalter an, Personenebene aus → reduzierter Modus.
      @sa = create(:state_association, referee_assignment_external_enabled: true)
      @go = create(:game_operation, state_association_id: @sa.id)
      @league = create(:league, game_operation: @go)
      @game_day = create(:game_day, league: @league, date: (Date.today + 7).to_s)
      @rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
    end

    test 'RSK im reduzierten Modus darf zugreifen, ohne Ansetzer-Rolle zu sein' do
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
    end

    test 'RSK ohne Hauptschalter bleibt draussen' do
      @sa.update!(referee_assignment_external_enabled: false)
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :forbidden
    end

    # Der Personen-Weg filtert auf die Markierung. Im reduzierten Modus darf er
    # nicht greifen, sonst sähe die RSK genau die Spiele nicht, die sie pflegen soll.
    test 'Spieleliste zeigt unmarkierte Spiele und sperrt die markierten' do
      offen = create(:game, game_day: @game_day, game_status: 'pregame', person_level_assignment: false)
      markiert = create(:game, game_day: @game_day, game_status: 'pregame', person_level_assignment: true)
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      rows = JSON.parse(response.body).index_by { |g| g['id'] }
      assert_includes rows.keys, offen.id
      assert_equal false, rows[offen.id]['locked']
      # Markierte Spiele werden gezeigt, aber gesperrt – ausgeblendet wüsste die
      # RSK nicht, warum ein Spiel fehlt.
      assert_includes rows.keys, markiert.id
      assert_equal true, rows[markiert.id]['locked']
    end

    test 'Verein ansetzen steht sofort im Spielplan und verschickt keine Mail' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      club = create(:club, state_association_id: @sa.id)
      login(@rsk)

      assert_no_enqueued_emails do
        patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
              params: { club_id: club.id }
      end

      assert_response :success
      assignment = game.reload.referee_assignment
      assert_equal club.id, assignment.club_id
      assert assignment.club_assignment?
      assert_nil assignment.referee1_id
      assert_nil assignment.referee2_id
      # Sofort öffentlich – einen Schritt „Veröffentlichen" wie im Personen-Weg
      # gibt es hier bewusst nicht.
      assert_equal club.name, game.nominated_referee_string
    end

    test 'Freitext ersetzt eine zuvor gewaehlte Vereins-Ansetzung samt Datensatz' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      club = create(:club, state_association_id: @sa.id)
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { club_id: club.id }
      assert_response :success

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { nominated_referee_string: 'Müller / Schmidt' }

      assert_response :success
      assert_equal 'Müller / Schmidt', game.reload.nominated_referee_string
      # Bleibt der Datensatz stehen, hält ihn der Filter „… ODER hat Ansetzung"
      # als Geist in der Liste fest.
      assert_nil game.referee_assignment
    end

    test 'markiertes Spiel ist im reduzierten Modus nicht bearbeitbar' do
      game = create(:game, game_day: @game_day, game_status: 'pregame', person_level_assignment: true)
      club = create(:club, state_association_id: @sa.id)
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { club_id: club.id }

      assert_response :unprocessable_entity
      assert_nil game.reload.referee_assignment
    end

    test 'RSK kommt nicht an den Personen-Weg' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      login(@rsk)

      get "/api/v2/admin/referee_assignments/available?date=#{Date.today + 7}"
      assert_response :forbidden

      post '/api/v2/admin/referee_assignments',
           params: { assignment: { game_id: game.id, status: 'tentative' } }
      assert_response :forbidden
    end

    # Eine RSK kann mehrere Verbände betreuen. In einem Verband, der auf der
    # Personenebene arbeitet, setzt die Ansetzer-Rolle an – dorthin darf der
    # reduzierte Modus nicht hineinschreiben.
    test 'RSK schreibt nicht in einen Verband auf der Personenebene' do
      sa_person = create(:state_association, referee_assignment_enabled: true)
      go_person = create(:game_operation, state_association_id: sa_person.id)
      league_person = create(:league, game_operation: go_person)
      gd_person = create(:game_day, league: league_person, date: (Date.today + 7).to_s)
      game = create(:game, game_day: gd_person, game_status: 'pregame')
      club = create(:club, state_association_id: sa_person.id)

      user = create(:user, permissions: [
        { 'user_group_id' => 3, 'game_operation_id' => @go.id },
        { 'user_group_id' => 3, 'game_operation_id' => go_person.id }
      ])
      login(user)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { club_id: club.id }

      assert_response :forbidden
      assert_nil game.reload.referee_assignment
    end

    test 'Vereinsauswahl bietet die Vereine der Liga an' do
      club_in_league = create(:club, state_association_id: @sa.id)
      create(:team, league: @league, club: club_in_league)
      club_elsewhere = create(:club, state_association_id: @sa.id)
      login(@rsk)

      get "/api/v2/admin/referee_assignments/league_clubs?league_id=#{@league.id}"

      assert_response :success
      ids = JSON.parse(response.body).map { |c| c['id'] }
      assert_includes ids, club_in_league.id
      assert_not_includes ids, club_elsewhere.id
    end

    # Ansetzer und Admin haben den Personen-Weg; im reduzierten Modus kämen sie an
    # der Sperre für markierte Spiele vorbei.
    test 'Ansetzer und Admin bekommen den reduzierten Modus nicht' do
      sa_person = create(:state_association, referee_assignment_enabled: true)
      go_person = create(:game_operation, state_association_id: sa_person.id)
      login(create(:user, :assigner_scoped, game_operation_id: go_person.id))

      get "/api/v2/admin/referee_assignments/league_clubs?league_id=#{@league.id}"
      assert_response :forbidden

      login(create(:user, :admin))
      get "/api/v2/admin/referee_assignments/league_clubs?league_id=#{@league.id}"
      assert_response :forbidden
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
