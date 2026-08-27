require 'test_helper'

module Admin
  # Spielerdaten-Rangliste (#465). Zwei Modi, die dasselbe zaehlen: der Vereinsmodus
  # das, was fuer diesen Verein gespielt wurde, der Verbandsmodus dasselbe ueber alle
  # Vereine des eigenen Spielbetriebs.
  class PlayerStatisticsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')

      @sa_ost = create(:state_association, name: 'Verband Ost')
      @go_ost = create(:game_operation, state_association_id: @sa_ost.id, name: 'SBK Ost', path: 'ost')
      @sa_west = create(:state_association, name: 'Verband West')
      @go_west = create(:game_operation, state_association_id: @sa_west.id, name: 'SBK West', path: 'west')

      @club = create(:club, name: 'Aal Berlin', game_operation: @go_ost)
      @club2 = create(:club, name: 'Bussard Leipzig', game_operation: @go_ost)
      @club_west = create(:club, name: 'Cormoran Koeln', game_operation: @go_west)

      @liga_ost = create(:league, game_operation: @go_ost, season_id: '18', name: 'Regionalliga Ost',
                                  league_class_id: 'rl')
      @liga_west = create(:league, game_operation: @go_west, season_id: '18', name: 'Regionalliga West',
                                   league_class_id: 'rl')

      @team = create(:team, league: @liga_ost, club: @club, name: 'Aal Berlin 1')
      @team2 = create(:team, league: @liga_ost, club: @club2, name: 'Bussard Leipzig 1')
      @team_west = create(:team, league: @liga_west, club: @club_west, name: 'Cormoran Koeln 1')

      # Zwei Einsaetze fuer den Verein, zwei Tore, eine Vorlage, 2 Strafminuten.
      @stamm = mitglied_von(@club, first_name: 'Anna', last_name: 'Adler')
      # Ein Einsatz, ein Tor -- fuer den zweiten Verein desselben Landesverbands.
      @nachbar = mitglied_von(@club2, first_name: 'Bea', last_name: 'Bussard')
      # Hat frueher fuer @club gespielt, ist heute im anderen Landesverband gemeldet.
      @ehemalige = mitglied_von(@club_west, first_name: 'Carla', last_name: 'Corvus')
      # Deaktiviert, aber weiter im Verein gemeldet.
      @deaktivierte = mitglied_von(@club, first_name: 'Dora', last_name: 'Dohle',
                                          deactivated_at: Time.current)
      @westlerin = mitglied_von(@club_west, first_name: 'Emma', last_name: 'Elster')

      spiel_ost(home_lineup: [aufstellung(7, @stamm), aufstellung(8, @ehemalige),
                              aufstellung(9, @deaktivierte)],
                events: [tor(7, assist: 8), tor(7), strafe(7, 'penalty_2')])
      spiel_ost(home_lineup: [aufstellung(7, @stamm)], events: [])
      spiel_ost(home_team: @team2, home_lineup: [aufstellung(11, @nachbar)], events: [tor(11)])
      create(:game, game_day: create(:game_day, league: @liga_west), home_team: @team_west,
                    guest_team: @team, ended: true, events: [tor(5)],
                    players: { 'home' => [aufstellung(5, @westlerin)], 'guest' => [] })

      PlayerStats::Refresher.new.run!
    end

    # ---------------------------------------------------------------- Rechte

    test 'der Vereinsmanager sieht die Rangliste seines Vereins' do
      login(create(:user, :vm, club_id: @club.id))
      body = statistics(club_id: @club.id)

      assert_response :success
      assert_equal 'club', body['scope']['mode']
      assert_equal ['Adler'], body['players'].pluck('last_name')
    end

    test 'ein fremder Vereinsmanager bekommt 403' do
      login(create(:user, :vm, club_id: @club_west.id))
      statistics(club_id: @club.id)

      assert_response :forbidden
    end

    test 'die zustaendige Spielbetriebskommission sieht den Verein, eine fremde nicht' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))
      statistics(club_id: @club.id)
      assert_response :success

      login(create(:user, :sbk_scoped, game_operation_id: @go_west.id))
      statistics(club_id: @club.id)
      assert_response :forbidden
    end

    test 'der Teammanager einer Mannschaft des Vereins darf lesen' do
      login(create(:user, :tm, team_id: @team.id))
      statistics(club_id: @club.id)

      assert_response :success
    end

    test 'der Admin darf beides' do
      login(create(:user, :admin))
      statistics(club_id: @club.id)
      assert_response :success

      statistics
      assert_response :success
    end

    test 'ohne Anmeldung 401, mit blossem API-Key ebenfalls' do
      statistics(club_id: @club.id)
      assert_response :unauthorized

      key, = ApiKey.generate(name: 'Test')
      get '/api/v2/admin/player_statistics.json', params: { club_id: @club.id },
                                                  headers: { 'X-Api-Key' => key }
      assert_response :unauthorized
    end

    test 'ein unbekannter Verein gibt 404' do
      login(create(:user, :admin))
      statistics(club_id: 999_999)

      assert_response :not_found
    end

    test 'Vereins- und Teammanager kommen nicht in die Verbandsansicht' do
      login(create(:user, :vm, club_id: @club.id))
      statistics

      assert_response :forbidden
    end

    # ---------------------------------------------------------------- Zaehlung

    test 'zaehlt Einsaetze, Tore, Vorlagen, Punkte und Strafminuten des Vereins' do
      login(create(:user, :admin))
      zeile = statistics(club_id: @club.id)['players'].first

      assert_equal 2, zeile['games']
      assert_equal 2, zeile['goals']
      assert_equal 0, zeile['assists']
      assert_equal 2, zeile['scorer_points']
      assert_equal 1.0, zeile['scorer_per_game']
      assert_equal 2, zeile['penalty_minutes']
      assert_equal '18', zeile['first_season_id']
      assert_equal '18', zeile['last_season_id']
    end

    # Der Verbandsmodus ist die Vereinigung ueber die Vereine des Spielbetriebs und
    # rechnet nicht anders: Wer nur fuer einen Verein gespielt hat, hat hier dieselben
    # Zahlen wie in dessen Vereinsansicht.
    test 'der Verbandsmodus zaehlt dasselbe wie der Vereinsmodus' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))

      im_verein = statistics(club_id: @club.id)['players'].find { |p| p['last_name'] == 'Adler' }
      im_verband = statistics['players'].find { |p| p['last_name'] == 'Adler' }

      assert_equal im_verein.slice('games', 'goals', 'assists', 'scorer_points', 'penalty_minutes'),
                   im_verband.slice('games', 'goals', 'assists', 'scorer_points', 'penalty_minutes')
    end

    test 'der Verbandsmodus fasst die Vereine des eigenen Spielbetriebs zusammen' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))
      body = statistics

      assert_equal 'association', body['scope']['mode']
      assert_equal %w[Adler Bussard], body['players'].pluck('last_name').sort
      assert_equal @club2.id, body['players'].find { |p| p['last_name'] == 'Bussard' }['home_club_id']
      assert_equal 'Bussard Leipzig', body['players'].find { |p| p['last_name'] == 'Bussard' }['home_club']
    end

    # Bundesweit gibt es keinen Vereinsfilter, gezaehlt wird also alles. Corvus ist
    # heute im Westen gemeldet und steht trotzdem drin: Sie hat Eins.aetze, und ihr
    # laufender Heimatverein ist einer -- mehr verlangt der Schalter nicht.
    test 'der Admin sieht in der Verbandsansicht beide Landesverbaende' do
      login(create(:user, :admin))

      assert_equal %w[Adler Bussard Corvus Elster], statistics['players'].pluck('last_name').sort
    end

    test 'ein Verein ausserhalb des eigenen Spielbetriebs ist als Filter nicht erlaubt' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))
      statistics(club_filter_id: @club_west.id)

      assert_response :forbidden
    end

    test 'der Vereinsfilter der Verbandsansicht schneidet auf einen Verein' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))

      assert_equal ['Bussard'], statistics(club_filter_id: @club2.id)['players'].pluck('last_name')
    end

    # ---------------------------------------------------------------- Schalter

    test 'ohne den Schalter stehen nur aktuell gemeldete Spieler in der Liste' do
      login(create(:user, :admin))

      assert_equal ['Adler'], statistics(club_id: @club.id)['players'].pluck('last_name')
    end

    # Ausgeschaltet kommen die Ehemaligen dazu, mit ihren damaligen Spielen fuer diesen
    # Verein. Die Zahlen der uebrigen aendern sich dabei nicht.
    test 'ohne die Meldebeschraenkung erscheinen auch Ehemalige mit ihren Spielen fuer den Verein' do
      login(create(:user, :admin))
      vorher = statistics(club_id: @club.id)['players'].first

      body = statistics(club_id: @club.id, only_current_members: false)

      assert_equal %w[Adler Corvus], body['players'].pluck('last_name').sort
      ehemalige = body['players'].find { |p| p['last_name'] == 'Corvus' }
      assert_equal 1, ehemalige['games']
      assert_equal 1, ehemalige['assists']
      assert_equal vorher.slice('games', 'goals', 'assists'),
                   body['players'].find { |p| p['last_name'] == 'Adler' }.slice('games', 'goals', 'assists')
    end

    test 'deaktivierte Spieler kommen nur auf Wunsch mit' do
      login(create(:user, :admin))

      assert_not_includes statistics(club_id: @club.id)['players'].pluck('last_name'), 'Dohle'
      body = statistics(club_id: @club.id, include_deactivated: true)
      dohle = body['players'].find { |p| p['last_name'] == 'Dohle' }
      assert_not_nil dohle
      assert_not_nil dohle['deactivated_at']
    end

    # ---------------------------------------------------------------- Filter

    test 'der Saisonfilter schneidet, ohne Treffer bleibt die Liste leer' do
      login(create(:user, :admin))

      assert_equal 1, statistics(club_id: @club.id, season_id: '18')['total']
      assert_equal 0, statistics(club_id: @club.id, season_id: '17')['total']
    end

    test 'die Auswahllisten enthalten nur Werte, die im Bestand vorkommen' do
      login(create(:user, :admin))
      filters = statistics(club_id: @club.id)['filters']

      assert_equal [{ 'id' => '18', 'name' => Setting.season_name('18') }], filters['seasons']
      assert_equal [@go_ost.id], filters['game_operations'].pluck('id')
      assert_equal ['rl'], filters['league_classes'].pluck('id')
      assert_equal [@liga_ost.id], filters['leagues'].pluck('id')
      assert_equal [@team.id], filters['teams'].pluck('id')
      assert_nil filters['clubs']
    end

    test 'die Verbandsansicht bietet Vereine statt Ligen und Mannschaften an' do
      login(create(:user, :sbk_scoped, game_operation_id: @go_ost.id))
      filters = statistics['filters']

      assert_equal [@club.id, @club2.id].sort, filters['clubs'].pluck('id').sort
      assert_nil filters['leagues']
      assert_nil filters['teams']
    end

    test 'Mindestspiele blenden Spieler unterhalb der Schwelle aus' do
      login(create(:user, :admin))

      assert_equal 1, statistics(club_id: @club.id, min_games: 2)['total']
      assert_equal 0, statistics(club_id: @club.id, min_games: 3)['total']
    end

    # ---------------------------------------------------------------- Reihenfolge

    test 'sortiert standardmaessig nach Spielen absteigend und laesst sich umdrehen' do
      login(create(:user, :admin))
      params = { club_id: @club.id, only_current_members: false, include_deactivated: true }

      assert_equal 3, statistics(**params)['total']
      assert_equal 2, statistics(**params)['players'].first['games']
      assert_equal 'Adler', statistics(**params, sort: 'goals')['players'].first['last_name']
      assert_equal 0, statistics(**params, sort: 'goals', sort_dir: 'asc')['players'].first['goals']
      assert_equal 'Adler', statistics(**params, sort: 'name')['players'].first['last_name']
    end

    test 'blaettert stabil und meldet die Gesamtzahl' do
      login(create(:user, :admin))
      params = { club_id: @club.id, only_current_members: false, include_deactivated: true }

      seite1 = statistics(**params, per_page: 1, page: 1)
      seite2 = statistics(**params, per_page: 1, page: 2)

      assert_equal 3, seite1['total']
      assert_equal 3, seite2['total']
      assert_equal 1, seite1['players'].size
      assert_not_equal seite1['players'].first['player_id'], seite2['players'].first['player_id']
    end

    test 'nennt den Stand der Berechnung' do
      login(create(:user, :admin))

      assert_not_nil statistics(club_id: @club.id)['as_of']
    end

    private

    def statistics(params = {})
      get '/api/v2/admin/player_statistics.json', params: params
      response.parsed_body
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def mitglied_von(club, attrs = {})
      create(:player, **attrs, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    end

    def spiel_ost(home_team: @team, home_lineup: [], events: [])
      create(:game, game_day: create(:game_day, league: @liga_ost), home_team:, guest_team: @team2,
                    ended: true, events:,
                    players: { 'home' => home_lineup, 'guest' => [] })
    end

    def aufstellung(number, player)
      { 'trikot_number' => number, 'player_id' => player.id,
        'player_firstname' => player.first_name, 'player_name' => player.last_name }
    end

    def tor(number, assist: nil)
      event = { 'home_number' => number, 'home_goals' => 1, 'guest_goals' => 0 }
      event['home_assist'] = assist if assist
      event
    end

    def strafe(number, mapping)
      { 'penalty_id' => 1, 'penalty_mapping' => mapping, 'home_number' => number }
    end
  end
end
