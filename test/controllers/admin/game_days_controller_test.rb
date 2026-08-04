require 'test_helper'

module Admin
  class GameDaysControllerTest < ActionDispatch::IntegrationTest
    OVERVIEW_PATH = '/api/v2/admin/game_days/report_overview'.freeze

    setup do
      create(:setting, current_season_id: '18')
      @sa = StateAssociation.create!(name: 'LV', scan_required: true)
      @go = GameOperation.create!(name: 'GO', short_name: 'GO', state_association_id: @sa.id)
      @league = create_league(@go, season_id: '18')
      @club = Club.create!(name: 'Verein', state_association_id: @sa.id)
      @arena = Arena.create!(name: 'Halle', city: 'Stadt')
      @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-02-01')
      @game = create_game(@game_day, game_number: '10')

      # Zweiter Spielbetrieb (fremder LV) für die Scope-Tests.
      @other_sa = StateAssociation.create!(name: 'LV2')
      @other_go = GameOperation.create!(name: 'GO2', short_name: 'GO2',
                                        state_association_id: @other_sa.id)
      @other_league = create_league(@other_go, season_id: '18')
      @other_game_day = GameDay.create!(league: @other_league, arena: @arena, club: @club,
                                        number: 1, date: '2026-02-08')
      @other_game = create_game(@other_game_day, game_number: '20')
    end

    test 'SBK sieht nur Spiele des eigenen Spielbetriebs' do
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal [@game.id], game_ids
    end

    test 'global gescopte SBK sieht alle Spielbetriebe' do
      login(sbk_user(0))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal [@game.id, @other_game.id].sort, game_ids.sort
    end

    test 'Nutzer ohne SBK-/Admin-Rechte bekommt 403' do
      login(create_user(user_group_id: 4, game_operation_id: 0))
      get OVERVIEW_PATH
      assert_response :forbidden
    end

    test 'ohne season_id greift die laufende Saison' do
      past_league = create_league(@go, season_id: '17')
      past_game_day = GameDay.create!(league: past_league, arena: @arena, club: @club,
                                      number: 1, date: '2025-02-01')
      past_game = create_game(past_game_day, game_number: '5')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal 18, Setting.current_season_id
      assert_equal [@game.id], game_ids
      assert_not_includes game_ids, past_game.id

      get OVERVIEW_PATH, params: { season_id: '17' }
      assert_equal [past_game.id], game_ids
    end

    test 'date_from und date_to filtern über die Textspalte game_days.date' do
      login(sbk_user(0))

      get OVERVIEW_PATH, params: { date_from: '2026-02-05' }
      assert_equal [@other_game.id], game_ids

      get OVERVIEW_PATH, params: { date_to: '2026-02-05' }
      assert_equal [@game.id], game_ids

      get OVERVIEW_PATH, params: { date_from: '2026-02-01', date_to: '2026-02-08' }
      assert_equal [@game.id, @other_game.id].sort, game_ids.sort
    end

    test 'record_comment wird ausgeliefert' do
      @game.update!(record_comment: 'Zeitnehmer fehlte in der 2. Drittelpause')
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_equal 'Zeitnehmer fehlte in der 2. Drittelpause', row(@game.id)['record_comment']
    end

    test 'leerer record_comment kommt als null' do
      @game.update!(record_comment: '')
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_nil row(@game.id)['record_comment']
    end

    test 'Scan-Metadaten inklusive Abstand zum Spieltag' do
      uploader = create_user(user_group_id: 3, game_operation_id: 0)
      scan = GameScan.new(game: @game, uploaded_by: uploader, expires_at: 12.months.from_now)
      scan.scan_file.attach(io: StringIO.new('PDF'), filename: 'bogen.pdf', content_type: 'application/pdf')
      scan.save!
      scan.update_column(:created_at, Time.zone.parse('2026-02-04 10:00'))

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      data = row(@game.id)
      assert data['scan_required']
      assert_equal 3, data['scan']['days_after_game_day']
      assert_equal uploader.fullname, data['scan']['uploaded_by_name']
      assert_not data['scan']['expired']
    end

    test 'ohne Scan ist scan null' do
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_nil row(@game.id)['scan']
    end

    test 'severe_penalty_count zählt ab 5 Minuten, nicht 2 Minuten' do
      @game.update!(events: [
        { 'penalty_id' => 1, 'penalty_mapping' => 'penalty_2', 'home_number' => 7 },
        { 'penalty_id' => 2, 'penalty_mapping' => 'penalty_5', 'home_number' => 8 },
        { 'penalty_id' => 3, 'penalty_mapping' => 'penalty_ms1', 'guest_number' => 9 },
        { 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 4 }
      ])
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_equal 2, row(@game.id)['flags']['severe_penalty_count']
    end

    test 'Auffälligkeiten und fehlende Pflichtangaben' do
      @game.update!(protest: true, forfait: 1, special_event_string: 'Hallenausfall',
                    referee2_string: '', audience: nil)
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      flags = row(@game.id)['flags']
      assert flags['protest']
      assert flags['forfait']
      assert_equal 'Hallenausfall', flags['special_event_string']
      assert flags['missing_referee2']
      assert flags['missing_audience']
      assert flags['missing_signatures']
    end

    test 'verknüpfte Vorgänge: Verfahrensvorschlag und verneinte Checklistenpunkte' do
      ProceedingProposal.create!(game: @game, state_association: @sa, status: 'pending')
      @game.update!(checklist_answers: [
        { 'item_id' => 1, 'question' => 'Halle in Ordnung?', 'answer' => true },
        { 'item_id' => 2, 'question' => 'Schiris pünktlich?', 'answer' => false }
      ])
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      data = row(@game.id)
      assert_equal 'pending', data['proceeding_proposal']['status']
      assert_equal 1, data['checklist_negative_count']
    end

    test 'Statusfelder und Zeitstempel des Berichts' do
      editor = create_user(user_group_id: 2, game_operation_id: @go.id)
      @game.update!(game_status: 'match_record_closed',
                    record_created_at: Time.zone.parse('2026-02-01 20:00'),
                    record_updated_at: Time.zone.parse('2026-02-01 21:30'),
                    record_updated_by: editor.id,
                    match_record_closed_at: Time.zone.parse('2026-02-01 21:35'))
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      data = row(@game.id)
      assert_equal 'match_record_closed', data['game_status']
      assert_equal editor.fullname, data['record_updated_by_name']
      assert data['record_created_at'].present?
      assert data['match_record_closed_at'].present?
    end

    private

    def body
      JSON.parse(response.body)
    end

    def game_ids
      body['games'].map { |g| g['id'] }
    end

    def row(game_id)
      body['games'].find { |g| g['id'] == game_id }
    end

    def create_league(game_operation, season_id:)
      League.create!(game_operation:, name: "Liga #{SecureRandom.hex(3)}",
                     season_id:, table_modus: 'classic')
    end

    def create_game(game_day, game_number:)
      home = Team.create!(league: game_day.league, club: @club, name: "H#{SecureRandom.hex(2)}")
      guest = Team.create!(league: game_day.league, club: @club, name: "G#{SecureRandom.hex(2)}")
      Game.create!(game_day:, home_team: home, guest_team: guest, game_number:,
                   forfait: 0, overtime: false, legacy: false,
                   events: [], players: { 'home' => [], 'guest' => [] })
    end

    def sbk_user(game_operation_id)
      create_user(user_group_id: 2, game_operation_id:)
    end

    def create_user(user_group_id:, game_operation_id:)
      User.create!(
        user_name: "authuser_#{SecureRandom.hex(4)}",
        first_name: 'Test',
        last_name: "User#{SecureRandom.hex(2)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
