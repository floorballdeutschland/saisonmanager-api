require 'test_helper'

module Admin
  class RefereesControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = User.create!(
        user_name: "refadmin_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
        teams: []
      )
    end

    test 'create legt Schiri an' do
      login(@admin)

      assert_difference -> { Referee.count }, 1 do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 987_654, vorname: 'Test', nachname: 'Schiri', email: 'test@example.org' }
        }
      end

      assert_response :created
    end

    test 'LV-RSK darf keinen neuen Schiedsrichter anlegen' do
      login(lv_rsk_user)

      assert_no_difference -> { Referee.count } do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 555_111, vorname: 'Neu', nachname: 'Schiri' }
        }
      end

      assert_response :forbidden
    end

    test 'FD-RSK darf einen neuen Schiedsrichter anlegen' do
      fd = create(:game_operation, :national)
      login(rsk_user(fd.id))

      assert_difference -> { Referee.count }, 1 do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 555_222, vorname: 'Neu', nachname: 'Schiri' }
        }
      end

      assert_response :created
    end

    test 'LV-RSK darf für einen bestehenden Schiri ein Benutzerkonto anlegen' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      referee = create(:referee, club_id: club.id, email: 'schiri@example.com')
      login(rsk_user(go.id))

      assert_difference -> { User.count }, 1 do
        post "/api/v2/admin/referees/#{referee.id}/create_user"
      end

      assert_response :success
    end

    test 'Benutzerkonto anlegen ohne E-Mail am Profil wird abgelehnt' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      referee = create(:referee, club_id: club.id, email: nil)
      login(rsk_user(go.id))

      assert_no_difference -> { User.count } do
        post "/api/v2/admin/referees/#{referee.id}/create_user"
      end

      assert_response :unprocessable_entity
      assert_match(/E-Mail-Adresse/, response.parsed_body['error'])
    end

    # Issue #60: VM ist serverseitig read-only – Lesen der Schiris des eigenen
    # Vereins bleibt erlaubt, Schreibaktionen (update/merge) sind gesperrt.
    test 'VM darf Schiris seines Vereins lesen (Liste + Detail)' do
      club = create(:club)
      referee = create(:referee, club_id: club.id)
      login(vm_user(club.id))

      get '/api/v2/admin/referees'
      assert_response :success
      assert_includes response.parsed_body.map { |r| r['id'] }, referee.id

      get "/api/v2/admin/referees/#{referee.id}"
      assert_response :success
    end

    test 'VM darf Schiris seines Vereins nicht bearbeiten' do
      club = create(:club)
      referee = create(:referee, club_id: club.id, vorname: 'Alt')
      login(vm_user(club.id))

      put "/api/v2/admin/referees/#{referee.id}", params: { referee: { vorname: 'Neu' } }

      assert_response :forbidden
      assert_equal 'Alt', referee.reload.vorname
    end

    test 'VM darf Schiris seines Vereins nicht zusammenführen' do
      club = create(:club)
      master = create(:referee, club_id: club.id)
      secondary = create(:referee, club_id: club.id)
      login(vm_user(club.id))

      post "/api/v2/admin/referees/#{master.id}/merge", params: { secondary_id: secondary.id }

      assert_response :forbidden
      assert_nil secondary.reload.merged_into_id
    end

    test 'Admin darf Schiris bearbeiten' do
      club = create(:club)
      referee = create(:referee, club_id: club.id, vorname: 'Alt')
      login(@admin)

      put "/api/v2/admin/referees/#{referee.id}", params: { referee: { vorname: 'Neu' } }

      assert_response :success
      assert_equal 'Neu', referee.reload.vorname
    end

    test 'destroy als FD-RSK löscht den Schiri, aber NICHT das verknüpfte Benutzerkonto' do
      fd = create(:game_operation, :national)
      referee = create(:referee)
      linked_user = referee_login_user(referee)
      login(rsk_user(fd.id))

      assert_no_difference -> { User.count } do
        assert_difference -> { Referee.count }, -1 do
          delete "/api/v2/admin/referees/#{referee.id}"
        end
      end

      assert_response :no_content
      assert_nil linked_user.reload.referee_id
    end

    test 'destroy als Admin löscht auch das verknüpfte Benutzerkonto' do
      referee = create(:referee)
      referee_login_user(referee)
      login(@admin)

      assert_difference -> { User.count }, -1 do
        assert_difference -> { Referee.count }, -1 do
          delete "/api/v2/admin/referees/#{referee.id}"
        end
      end

      assert_response :no_content
    end

    test 'index: season_game_count zählt Spiele kanonisch über officiating_referee_ids (PK)' do
      referee = create(:referee, lizenznummer: 700_123)
      go      = create(:game_operation)
      club    = create(:club)
      arena   = create(:arena)
      league  = create(:league, game_operation: go, season_id: '18')
      day     = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2025-01-01')
      Game.create!(game_day: day, officiating_referee_ids: [referee.id, 0],
                   events: [], players: { 'home' => [], 'guest' => [] },
                   forfait: 0, overtime: false, legacy: false)
      login(@admin)

      get '/api/v2/admin/referees'

      assert_response :success
      entry = response.parsed_body.find { |r| r['id'] == referee.id }
      assert_equal 1, entry['season_game_count']
    end

    test 'partners aggregiert gemeinsame Einsätze und trennt laufende Saison von der Gesamthistorie' do
      referee = create(:referee)
      often   = create(:referee, nachname: 'Oft')
      once    = create(:referee, nachname: 'Selten')
      partner_game([referee.id, often.id])
      partner_game([referee.id, often.id], season_id: '17')
      partner_game([referee.id, once.id], season_id: '17')
      login(@admin)

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
      body = response.parsed_body
      assert_equal referee.id, body['referee']['id']
      assert_equal 18, body['season_id']
      assert body['notice'].present?, 'Hinweis zur Belastbarkeit der Altdaten fehlt'

      partners = body['partners']
      # Sortierung: laufende Saison zuerst, dann Gesamtzahl
      assert_equal([often.id, once.id], partners.map { |p| p['referee_id'] })
      assert_equal 1, partners[0]['games_current_season']
      assert_equal 2, partners[0]['games_total']
      assert_equal 18, partners[0]['last_season_id']
      assert_equal 'Saison 2025/26', partners[0]['last_season_name']
      assert_equal 0, partners[1]['games_current_season']
      assert_equal 1, partners[1]['games_total']
      assert_equal 'Saison 2024/25', partners[1]['last_season_name']
    end

    test 'partners weist weder Gäste-Schiedsrichter noch den Schiri selbst als Partner aus' do
      referee = create(:referee)
      guest   = create(:referee, guest: true, lizenznummer: nil)
      regular = create(:referee)
      partner_game([referee.id, guest.id, regular.id])
      login(@admin)

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
      ids = response.parsed_body['partners'].map { |p| p['referee_id'] }
      assert_equal [regular.id], ids
      assert_not_includes ids, guest.id
      assert_not_includes ids, referee.id
    end

    test 'partners schlüsselt die Einsätze zusätzlich nach Spielbetrieb auf' do
      referee = create(:referee)
      partner = create(:referee)
      go_a = create(:game_operation, name: 'Verband A')
      go_b = create(:game_operation, name: 'Verband B')
      2.times { partner_game([referee.id, partner.id], game_operation: go_a) }
      partner_game([referee.id, partner.id], game_operation: go_b)
      login(@admin)

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
      entry = response.parsed_body['partners'].first
      assert_equal 3, entry['games_total']
      assert_equal([['Verband A', 2], ['Verband B', 1]],
                   entry['game_operations'].map { |g| [g['game_operation_name'], g['game_count']] })
    end

    test 'partners zählt nur tatsächliche Einsätze, nicht die reine Ansetzung' do
      referee = create(:referee)
      nominated_only = create(:referee)
      game = partner_game([referee.id])
      game.update!(nominated_referee_ids: [referee.id, nominated_only.id])
      login(@admin)

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
      assert_empty response.parsed_body['partners']
    end

    test 'LV-RSK darf die Gespann-Historie eines Schiris im eigenen Bestand abrufen' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      referee = create(:referee, club_id: create(:club, state_association_id: sa.id).id)
      login(rsk_user(go.id))

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
    end

    test 'Ansetzer darf die Gespann-Historie im eigenen Bestand abrufen' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      referee = create(:referee, club_id: create(:club, state_association_id: sa.id).id)
      login(create(:user, :assigner_scoped, game_operation_id: go.id))

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
    end

    # Die Auswertung zeigt bewusst auch Partner aus anderen Verbänden, sonst
    # unterschätzt sie die Belastung eines Schiris systematisch. Das ist zugleich
    # der Grund für include_vm: false in der Action.
    test 'partners zeigt auch Partner aus einem fremden Landesverband' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      referee = create(:referee, club_id: create(:club, state_association_id: sa.id).id)
      foreign = create(:referee, club_id: create(:club, state_association_id: create(:state_association).id).id)
      partner_game([referee.id, foreign.id])
      login(rsk_user(go.id))

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :success
      assert_equal([foreign.id], response.parsed_body['partners'].map { |p| p['referee_id'] })
    end

    test 'VM darf die Gespann-Historie eines Vereins-Schiris nicht abrufen' do
      club = create(:club)
      referee = create(:referee, club_id: club.id)
      login(vm_user(club.id))

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :forbidden
    end

    test 'LV-RSK darf die Gespann-Historie eines fremden Schiris nicht abrufen' do
      referee = create(:referee, club_id: create(:club).id)
      login(lv_rsk_user)

      get "/api/v2/admin/referees/#{referee.id}/partners"

      assert_response :forbidden
    end

    private

    # Spiel mit tatsächlich eingesetzten Schiris (officiating_referee_ids).
    def partner_game(referee_ids, season_id: '18', game_operation: nil)
      league = create(:league,
                      game_operation: game_operation || create(:game_operation),
                      season_id: season_id)
      create(:game,
             game_day: create(:game_day, league: league),
             officiating_referee_ids: referee_ids)
    end

    def vm_user(club_id)
      User.create!(
        user_name: "vm_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 4, 'club_id' => club_id }],
        teams: []
      )
    end

    # Schiri-Benutzerkonto (user_group 6), das mit dem Referee verknüpft ist.
    def referee_login_user(referee)
      User.create!(
        user_name: "sr_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 6 }],
        referee_id: referee.id,
        teams: []
      )
    end

    # RSK-Nutzer für einen konkreten Spielbetrieb (nationaler GO ⇒ FD/global,
    # sonst LV-gescopt).
    def rsk_user(go_id)
      User.create!(
        user_name: "rsk_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 3, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    def lv_rsk_user
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      rsk_user(go.id)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
