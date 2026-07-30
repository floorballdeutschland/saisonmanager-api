require 'test_helper'

module Admin
  # Tests für die Team-Zuweisung an TM-Konten (Admin::UsersController#create /
  # #update). Eine verlorene Zuweisung sperrt das Konto beim Login aus
  # (User#permissions_items → login_blocked), daher sind alle Wege abgedeckt,
  # auf denen teams gesetzt bzw. wieder geleert wird.
  class UsersTeamAssignmentTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @admin = create(:user, :admin)
      @club = create(:club)
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
    end

    test 'Anlage mit Vorsaison-Team wird abgelehnt statt still verworfen' do
      login(@admin)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'tm.alt', first_name: 'Alt', last_name: 'TM', email: 'alt@example.org' },
        role: { user_group_id: 5, club_id: @club.id },
        teams: [@old_team.id]
      }
      assert_response :unprocessable_entity
      assert_nil User.find_by(user_name: 'tm.alt')
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

    # --- Bearbeiten --------------------------------------------------------

    test 'Team-Zuweisung nachträglich setzen' do
      tm = create(:user, :tm, team_id: @old_team.id)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@team.id] }
      assert_response :success
      assert_equal [@team.id], tm.reload.teams
    end

    test 'Zuweisung auf Vorsaison-Team wird abgelehnt' do
      tm = create(:user, :tm, team_id: @team.id)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@old_team.id] }
      assert_response :unprocessable_entity
      assert_equal [@team.id], tm.reload.teams
    end

    test 'unveränderter Verein löscht die Team-Zuweisung nicht' do
      tm = create(:user, :tm, team_id: @team.id)
      tm.update!(club_id: @club.id)
      login(@admin)

      # Genau der Request des Haupt-„Speichern": club_id wird unverändert
      # mitgesendet. Früher leerte apply_club_change dabei teams.
      patch "/api/v2/admin/users/#{tm.id}", params: { email: 'neu@example.org', club_id: @club.id }
      assert_response :success

      tm.reload
      assert_equal [@team.id], tm.teams
      assert_equal 'neu@example.org', tm.email
    end

    test 'echter Vereinswechsel leert die Team-Zuweisung' do
      tm = create(:user, :tm, team_id: @team.id)
      tm.update!(club_id: @club.id)
      other_club = create(:club)
      login(@admin)

      patch "/api/v2/admin/users/#{tm.id}", params: { club_id: other_club.id }
      assert_response :success
      assert_equal [], tm.reload.teams
    end

    test 'teams und club_id im selben Request behalten die Zuweisung' do
      tm = create(:user, :tm, team_id: @old_team.id)
      tm.update!(club_id: @club.id)
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

    test 'reines RSK-Konto darf keine Teams zuweisen' do
      rsk = create(:user, :rsk_scoped, game_operation_id: 1)
      # Der TM muss im Lese-Scope des RSK liegen, sonst greift schon
      # set_managed_user (404) und die Rechteprüfung wäre nicht getestet.
      scoped_club = create(:club, game_operations_hash: [{ 'game_operation_id' => 1, 'home_game_operation' => true }])
      tm = create(:user, :tm, team_id: @old_team.id)
      tm.update!(club_id: scoped_club.id)
      login(rsk)

      patch "/api/v2/admin/users/#{tm.id}", params: { teams: [@team.id] }
      assert_response :forbidden
      assert_equal [@old_team.id], tm.reload.teams
    end

    # --- Login-Meldung -----------------------------------------------------

    test 'Konto ohne jede Zuweisung nennt die fehlende Team-Zuweisung' do
      tm = create(:user, :tm, team_id: @team.id)
      tm.update!(teams: [])

      assert_match(/kein Team zugewiesen/, tm.login_blocked_message)
    end

    test 'Konto mit veralteter Zuweisung nennt die Saison' do
      tm = create(:user, :tm, team_id: @old_team.id)

      assert_equal 'Keine Teams in der aktuellen Saison.', tm.login_blocked_message
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
