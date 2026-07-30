require 'test_helper'

module Admin
  class RefereeAssignmentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
    end

    test 'LV-Ansetzer ohne freigeschaltete Ansetzung (Feature-Flag) erhält 403' do
      sa = create(:state_association) # referee_assignment_enabled default: false
      go = create(:game_operation, state_association_id: sa.id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :forbidden
    end

    test 'LV-Ansetzer mit freigeschalteter Ansetzung darf zugreifen' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :success
    end

    test 'FD-Ansetzer (nationaler Spielbetrieb) ist immer aktiv' do
      fd = create(:game_operation, :national)
      login(create(:user, :assigner_scoped, game_operation_id: fd.id))

      get '/api/v2/admin/referee_assignments'

      assert_response :success
    end

    test 'available_coaches liefert dem LV-Ansetzer nur Coaches des eigenen Verbands' do
      sa_own = create(:state_association, referee_assignment_enabled: true)
      go_own = create(:game_operation, state_association_id: sa_own.id)
      sa_other = create(:state_association, referee_assignment_enabled: true)
      create(:game_operation, state_association_id: sa_other.id)

      club_own = create(:club, state_association_id: sa_own.id)
      club_other = create(:club, state_association_id: sa_other.id)

      date = Date.today + 7
      coach_own = coach_referee(club_own, date)
      coach_other = coach_referee(club_other, date)

      login(create(:user, :assigner_scoped, game_operation_id: go_own.id))
      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      ids = JSON.parse(response.body).map { |c| c['id'] }
      assert_includes ids, coach_own.id
      assert_not_includes ids, coach_other.id
    end

    test 'available liefert die Vereins-Ausschlussliste mit, filtert aber niemanden heraus' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      own_club = create(:club, state_association_id: sa.id)
      excluded_club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      referee = create(:referee, club_id: own_club.id)
      RefereeAvailability.create!(referee: referee, date: date)
      RefereeClubExclusion.create!(referee: referee, club: excluded_club, reason: 'Sohn spielt dort')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == referee.id }
      assert_not_nil entry, 'gesperrte Person bleibt waehlbar'
      assert_equal [own_club.id, excluded_club.id].sort, entry['excluded_club_ids'].sort
    end

    test 'available_coaches liefert die Vereins-Ausschlussliste mit' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      excluded_club = create(:club, state_association_id: sa.id)

      date = Date.today + 7
      coach = coach_referee(club, date)
      RefereeClubExclusion.create!(referee: coach, club: excluded_club, reason: 'Eigene Mannschaft')

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get "/api/v2/admin/referee_assignments/available_coaches?date=#{date}"

      assert_response :success
      entry = JSON.parse(response.body).find { |r| r['id'] == coach.id }
      assert_equal [club.id, excluded_club.id].sort, entry['excluded_club_ids'].sort
    end

    test 'Ansetzer im Scope pflegt und leert die Spielinformationen' do
      sa = create(:state_association, referee_assignment_enabled: true)
      go = create(:game_operation, state_association_id: sa.id)
      game = assignable_game(go)
      user = create(:user, :assigner_scoped, game_operation_id: go.id,
                                             first_name: 'Anna', last_name: 'Ansetzer')
      login(user)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: '  Halle nur über den Hintereingang  ' } }

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'Halle nur über den Hintereingang', body['referee_notes']
      assert_equal 'Anna Ansetzer', body['referee_notes_updated_by_name']
      assert_not_nil body['referee_notes_updated_at']
      assert_equal 'Halle nur über den Hintereingang', game.reload.referee_notes
      assert_equal user.id, game.referee_notes_updated_by

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: '   ' } }

      assert_response :success
      assert_nil game.reload.referee_notes
    end

    test 'Ansetzer eines fremden Verbands darf die Spielinformationen nicht ändern' do
      sa_own = create(:state_association, referee_assignment_enabled: true)
      go_own = create(:game_operation, state_association_id: sa_own.id)
      sa_other = create(:state_association, referee_assignment_enabled: true)
      go_other = create(:game_operation, state_association_id: sa_other.id)
      game = assignable_game(go_other)
      game.update!(referee_notes: 'Fremder Hinweis')

      login(create(:user, :assigner_scoped, game_operation_id: go_own.id))
      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: 'Übergriff' } }

      assert_response :forbidden
      assert_equal 'Fremder Hinweis', game.reload.referee_notes
    end

    test 'Rolle ohne Ansetzungsrecht darf die Spielinformationen nicht ändern' do
      go = create(:game_operation, :national)
      game = assignable_game(go)

      login(create(:user, :sbk_global))
      patch "/api/v2/admin/referee_assignments/games/#{game.id}/notes",
            params: { game: { referee_notes: 'Von der SBK' } }

      assert_response :forbidden
      assert_nil game.reload.referee_notes
    end

    test 'Liste der ansetzbaren Spiele liefert die Spielinformationen mit Autor' do
      go = create(:game_operation, :national)
      game = assignable_game(go)
      author = create(:user, :assigner_scoped, game_operation_id: go.id,
                                               first_name: 'Bea', last_name: 'Bezirk')
      game.update!(referee_notes: 'Turniermodus, 2×15 Minuten',
                   referee_notes_updated_at: Time.current,
                   referee_notes_updated_by: author.id)

      login(create(:user, :assigner_scoped, game_operation_id: go.id))
      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      entry = JSON.parse(response.body).find { |g| g['id'] == game.id }
      assert_equal 'Turniermodus, 2×15 Minuten', entry['referee_notes']
      assert_equal 'Bea Bezirk', entry['referee_notes_updated_by_name']
      assert_not_nil entry['referee_notes_updated_at']
    end

    private

    # Spiel, das in der Ansetzungs-Liste auftaucht: noch nicht begonnen und über
    # den Sentinel im nominated_referee_string zur RSK-Ansetzung markiert.
    def assignable_game(game_operation)
      league = create(:league, game_operation: game_operation)
      game_day = create(:game_day, league: league, date: (Date.today + 7).to_s)
      create(:game, game_day: game_day, game_status: 'pregame',
                    nominated_referee_string: RefereeAssignmentsController::RSK_ASSIGNMENT_MARKER)
    end

    # Schiri mit gültiger B-Zusatzlizenz und hinterlegter Verfügbarkeit am Datum.
    def coach_referee(club, date)
      referee = create(:referee, club_id: club.id)
      type = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
      RefereeQualification.create!(referee: referee, referee_qualification_type: type, valid_until: nil)
      RefereeAvailability.create!(referee: referee, date: date)
      referee
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
