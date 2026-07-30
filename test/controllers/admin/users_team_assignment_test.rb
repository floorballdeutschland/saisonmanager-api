require 'test_helper'

module Admin
  # Team-Zuweisung an TM-Konten. Eine verlorene Zuweisung sperrt das Konto beim
  # Login aus (User#permissions_items → login_blocked), deshalb sind die Wege
  # abgedeckt, auf denen teams gesetzt bzw. geleert wird: #create (Admin/SBK und
  # VM), #update mit teams, #update mit club_id.
  class UsersTeamAssignmentTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @admin = create(:user, :admin)
      @go = create(:game_operation)
      @club = create(:club, game_operations_hash: [{ 'game_operation_id' => @go.id, 'home_game_operation' => true }])
      @current_league = create(:league, :current_season)
      @previous_league = create(:league, :previous_season)
      @team = create(:team, club: @club, league: @current_league)
      @old_team = create(:team, club: @club, league: @previous_league)
    end

    # --- Anlage ------------------------------------------------------------

    test 'Admin legt TM-Konto mit Team-Zuweisung an' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neuer.tm', first_name: 'Neuer', last_name: 'TM', email: 'tm@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [@team.id]
      }
      assert_response :created

      created = User.find_by(user_name: 'neuer.tm')
      assert_equal [@team.id], created.teams
    end

    test 'angelegtes TM-Konto mit Team ist nicht ausgesperrt' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.mit.team', first_name: 'Mit', last_name: 'Team', email: 'mit@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [@team.id]
      }
      assert_response :created

      created = User.find_by(user_name: 'tm.mit.team')
      refute created.permissions_items[:login_blocked]
      assert_nil created.login_blocked_message
    end

    test 'SBK legt TM-Konto mit Team des eigenen Verbands an' do
      sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
      login(sbk)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.sbk', first_name: 'Sbk', last_name: 'TM', email: 'sbk@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [@team.id]
      }
      assert_response :created
      assert_equal [@team.id], User.find_by(user_name: 'tm.sbk').teams
    end

    test 'SBK kann kein Team eines fremden Verbands zuweisen' do
      sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
      foreign_go = create(:game_operation)
      foreign_club = create(:club,
                            game_operations_hash: [{ 'game_operation_id' => foreign_go.id,
                                                     'home_game_operation' => true }])
      foreign_team = create(:team, club: foreign_club, league: @current_league)
      login(sbk)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.fremdgo', first_name: 'Fremd', last_name: 'Go', email: 'fgo@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [foreign_team.id]
      }
      assert_response :unprocessable_entity
      assert_nil User.find_by(user_name: 'tm.fremdgo')
    end

    test 'Anlage mit Vorsaison-Team wird abgelehnt statt still verworfen' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.alt', first_name: 'Alt', last_name: 'TM', email: 'alt@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [@old_team.id]
      }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)['error'], @old_team.id.to_s
      assert_nil User.find_by(user_name: 'tm.alt')
    end

    test 'Anlage mit Team eines anderen Vereins wird abgelehnt' do
      other_team = create(:team, club: create(:club), league: @current_league)
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.andersverein', first_name: 'Anderer', last_name: 'Verein', email: 'av@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [other_team.id]
      }
      assert_response :unprocessable_entity
      assert_nil User.find_by(user_name: 'tm.andersverein')
    end

    test 'Anlage ohne teams-Parameter bleibt möglich' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.ohne', first_name: 'Ohne', last_name: 'Team', email: 'ohne@example.org' },
        role: { user_group_id: 5, club_id: @club.id }
      }
      assert_response :created
      assert_equal [], User.find_by(user_name: 'tm.ohne').teams
    end

    test 'teams an einer Nicht-TM-Rolle wird ignoriert' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neuer.vm', first_name: 'Neuer', last_name: 'VM', email: 'vm@example.org' },
        role: { user_group_id: 4, club_id: @club.id },
        teams: [@team.id]
      }
      assert_response :created
      assert_equal [], User.find_by(user_name: 'neuer.vm').teams
    end

    test 'VM legt TM-Konto nur mit Team des eigenen Vereins an' do
      vm = create(:user, :vm, club_id: @club.id)
      foreign_team = create(:team, club: create(:club), league: @current_league)
      login(vm)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.fremd', first_name: 'Fremd', last_name: 'Team', email: 'fremd@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [foreign_team.id]
      }
      assert_response :unprocessable_entity
      assert_nil User.find_by(user_name: 'tm.fremd')
    end

    test 'VM kann ein SG-Team des eigenen Vereins zuweisen' do
      partner = create(:club)
      sg_team = create(:team, club: partner, league: @current_league, syndicate: true,
                              syndicate_clubs: [@club.id])
      vm = create(:user, :vm, club_id: @club.id)
      login(vm)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.sg', first_name: 'Sg', last_name: 'Team', email: 'sg@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [sg_team.id]
      }
      assert_response :created
      assert_equal [sg_team.id], User.find_by(user_name: 'tm.sg').teams
    end

    # --- Bearbeiten --------------------------------------------------------

    test 'Team-Zuweisung nachträglich setzen' do
      tm = tm_user(teams: [@old_team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@team.id] }
      assert_response :success
      assert_equal [@team.id], tm.reload.teams
    end

    test 'Zuweisung auf Vorsaison-Team wird abgelehnt' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@old_team.id] }
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)['error'], @old_team.id.to_s
      assert_equal [@team.id], tm.reload.teams
    end

    test 'unbrauchbare teams-Werte löschen die Zuweisung nicht' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: ['abc'] }, as: :json
      assert_response :unprocessable_entity
      assert_equal [@team.id], tm.reload.teams
    end

    test 'teams als Objekt statt Liste ergibt 422, keinen Serverfehler' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: { '0' => @team.id } }, as: :json
      assert_response :unprocessable_entity
      assert_equal [@team.id], tm.reload.teams
    end

    test 'leere Liste entfernt die Zuweisung bewusst' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [] }, as: :json
      assert_response :success
      assert_equal [], tm.reload.teams
    end

    test 'unveränderter Verein löscht die Team-Zuweisung nicht' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      # Genau der Request des Haupt-„Speichern": club_id wird unverändert
      # mitgesendet. Früher leerte apply_club_change dabei teams.
      patch "/api/v2/admin/users/#{tm.id}", params: { email: 'neu@example.org', club_id: @club.id }
      assert_response :success

      tm.reload
      assert_equal [@team.id], tm.teams
      assert_equal 'neu@example.org', tm.email
    end

    test 'unveränderter Verein aus der Rollen-Berechtigung löscht die Zuweisung nicht' do
      # Spalte und Berechtigung driften auseinander (apply_club_change zog die
      # TM-Berechtigung früher nicht mit). Die Maske sendet den Wert aus der
      # Berechtigung, der Vergleich muss ihn deshalb kennen.
      tm = tm_user(teams: [@team.id])
      tm.update!(club_id: create(:club).id)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { club_id: @club.id }
      assert_response :success
      assert_equal [@team.id], tm.reload.teams
    end

    test 'echter Vereinswechsel leert die Team-Zuweisung' do
      tm = tm_user(teams: [@team.id])
      other_club = create(:club)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { club_id: other_club.id }
      assert_response :success
      assert_equal [], tm.reload.teams
    end

    test 'Vereinswechsel zieht die TM-Berechtigung mit' do
      tm = tm_user(teams: [@team.id])
      other_club = create(:club)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { club_id: other_club.id }
      assert_response :success

      perm = tm.reload.permissions.find { |p| p['user_group_id'].to_i == 5 }
      assert_equal other_club.id.to_s, perm['club_id']
    end

    test 'teams und club_id im selben Request behalten die Zuweisung' do
      tm = tm_user(teams: [@old_team.id])
      other_club = create(:club)
      team_of_other_club = create(:team, club: other_club, league: @current_league)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: {
        club_id: other_club.id,
        teams: [team_of_other_club.id]
      }
      assert_response :success

      tm.reload
      assert_equal other_club.id, tm.club_id
      assert_equal [team_of_other_club.id], tm.teams
    end

    test 'Team des alten Vereins wird beim Vereinswechsel abgelehnt' do
      tm = tm_user(teams: [])
      other_club = create(:club)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: {
        club_id: other_club.id,
        teams: [@team.id]
      }
      assert_response :unprocessable_entity
      assert_equal @club.id, tm.reload.club_id
    end

    test 'Rolle und Zuweisung im selben Request werden abgelehnt' do
      tm = tm_user(teams: [@team.id])
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { role: 4, club_id: @club.id }
      assert_response :unprocessable_entity
      assert_equal [5], tm.reload.permissions.map { |p| p['user_group_id'].to_i }
    end

    test 'VM kann kein fremdes Team nachträglich zuweisen' do
      vm = create(:user, :vm, club_id: @club.id)
      tm = tm_user(teams: [@team.id])
      foreign_team = create(:team, club: create(:club), league: @current_league)
      login(vm)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [foreign_team.id] }
      assert_response :unprocessable_entity
      assert_equal [@team.id], tm.reload.teams
    end

    test 'reines RSK-Konto darf keine Teams zuweisen' do
      rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
      # Der TM muss im Lese-Scope des RSK liegen, sonst greift schon
      # set_managed_user (404) und die Rechteprüfung wäre nicht getestet.
      tm = tm_user(teams: [@old_team.id])
      login(rsk)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@team.id] }
      assert_response :forbidden
      assert_includes JSON.parse(response.body)['error'], 'Teams zuzuweisen'
      assert_equal [@old_team.id], tm.reload.teams
    end

    # --- Login-Meldung -----------------------------------------------------

    test 'Konto ohne jede Zuweisung nennt die fehlende Team-Zuweisung' do
      tm = tm_user(teams: [])

      post '/api/v2/login', params: { username: tm.user_name, password: 'password123' }
      assert_response :success
      assert_match(/kein Team zugewiesen/, JSON.parse(response.body).dig('user', 'login_blocked_message'))
    end

    test 'Konto mit veralteter Zuweisung nennt die Saison' do
      tm = tm_user(teams: [@old_team.id])

      post '/api/v2/login', params: { username: tm.user_name, password: 'password123' }
      assert_response :success
      assert_equal 'Keine Teams in der aktuellen Saison.',
                   JSON.parse(response.body).dig('user', 'login_blocked_message')
    end

    test 'Konto mit gelöschtem Team nennt die gelöschten Teams' do
      tm = tm_user(teams: [@old_team.id])
      @old_team.destroy!

      post '/api/v2/login', params: { username: tm.user_name, password: 'password123' }
      assert_response :success
      assert_match(/existieren nicht mehr/, JSON.parse(response.body).dig('user', 'login_blocked_message'))
    end

    test 'nicht gesperrtes Konto hat keine Sperr-Meldung' do
      tm = tm_user(teams: [@team.id])

      post '/api/v2/login', params: { username: tm.user_name, password: 'password123' }
      assert_response :success
      assert_nil JSON.parse(response.body).dig('user', 'login_blocked_message')
    end

    # --- Sperr-Kennzeichnung in der Liste ----------------------------------

    test 'login_blocked deckt sich mit permissions_items' do
      # Hält die batch-optimierte Herleitung in Admin::UsersController mit der
      # maßgeblichen in User#permissions_items zusammen. Läuft eine der beiden
      # weg, schlägt dieser Test fehl statt die Liste falsch zu markieren.
      cases = {
        'nur TM, Saison-Team' => [{ 'user_group_id' => 5 }, [@team.id]],
        'nur TM, Vorsaison-Team' => [{ 'user_group_id' => 5 }, [@old_team.id]],
        'nur TM, ohne Team' => [{ 'user_group_id' => 5 }, []],
        'TM + RSK, ohne Team' => [{ 'user_group_id' => 3, 'game_operation_id' => @go.id }, []],
        'TM + Ansetzer, ohne Team' => [{ 'user_group_id' => 7, 'game_operation_id' => @go.id }, []],
        'TM + Schiri, ohne Team' => [{ 'user_group_id' => 6 }, []],
        'TM + VM, ohne Team' => [{ 'user_group_id' => 4, 'club_id' => @club.id.to_s }, []]
      }

      login(@admin)
      get '/api/v2/admin/users'
      assert_response :success

      cases.each do |label, (extra_perm, teams)|
        perms = [{ 'user_group_id' => 5 }]
        perms << extra_perm unless extra_perm['user_group_id'] == 5
        user = create(:user).tap { |u| u.update!(permissions: perms, teams: teams) }

        get '/api/v2/admin/users'
        assert_response :success
        row = JSON.parse(response.body).find { |r| r['id'] == user.id }
        refute_nil row, "#{label}: Konto fehlt in der Liste"
        assert_equal user.permissions_items[:login_blocked].present?, row['login_blocked'], label
      end
    end

    private

    # TM-Konto mit Verein in Spalte UND Rollen-Berechtigung, so wie #create es
    # anlegt. Ohne den Verein in der Berechtigung liefen die Vereinswechsel-Tests
    # an einem unrealistischen Datenstand.
    def tm_user(teams:)
      create(:user, :tm).tap do |u|
        u.update!(teams: teams,
                  club_id: @club.id,
                  permissions: [{ 'user_group_id' => 5, 'club_id' => @club.id.to_s }])
      end
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
