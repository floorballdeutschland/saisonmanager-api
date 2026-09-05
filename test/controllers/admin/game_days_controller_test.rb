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

    test 'nur die laufende Saison, auch auf Anfrage keine Altsaison' do
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

      # season_id ist bewusst kein Parameter – ein mitgeschickter Wert darf die
      # Saisonbindung nicht aufweichen.
      get OVERVIEW_PATH, params: { season_id: '17' }
      assert_response :success
      assert_equal [@game.id], game_ids
      assert_not_includes game_ids, past_game.id
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

    test 'nicht-numerische Spielnummern brechen die Sortierung nicht ab' do
      # K.-o.-Runden vergeben Spielnummern wie „HF1" oder „FIN". Ein blanker
      # ::integer-Cast in der ORDER BY liess Postgres die ganze Abfrage abbrechen.
      create_game(@game_day, game_number: 'HF1')
      create_game(@game_day, game_number: 'Pl. 3')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal 3, body['games'].size
    end

    test 'leeres Spieltagsdatum bricht den Datumsfilter nicht ab' do
      empty_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '')
      create_game(empty_day, game_number: '99')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH, params: { date_from: '2026-01-01' }
      assert_response :success
      assert_equal [@game.id], game_ids
    end

    test 'ungueltige Filterwerte liefern 422 statt 500' do
      login(sbk_user(@go.id))

      get OVERVIEW_PATH, params: { date_from: 'gestern' }
      assert_response :unprocessable_entity
      assert_match(/JJJJ-MM-TT/, body['message'])

      get OVERVIEW_PATH, params: { league_id: 'abc' }
      assert_response :unprocessable_entity
    end

    test 'neueste Spieltage stehen oben und ueberleben das Deckeln' do
      later_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-03-01')
      later_game = create_game(later_day, game_number: '50')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_equal [later_game.id, @game.id], game_ids
    end

    test 'eine kaputte Zeile setzt nicht die ganze Uebersicht auf 500' do
      # Ereignis-JSONB aus Alt-Importen ist nicht formstabil.
      @game.update_columns(events: [42, nil, { 'penalty_id' => 2, 'penalty_mapping' => 'penalty_5' }])

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal 1, row(@game.id)['flags']['severe_penalty_count']
    end

    test 'formfremde Checklisten-Antworten werden nicht gezaehlt' do
      @game.update_columns(checklist_answers: { 'foo' => false })
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_response :success
      assert_equal 0, row(@game.id)['checklist_negative_count']
    end

    test 'null Zuschauer gilt als Angabe, fehlende Angabe wird gemeldet' do
      @game.update!(audience: 0)
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert_not row(@game.id)['flags']['missing_audience']

      @game.update!(audience: nil)
      get OVERVIEW_PATH
      assert row(@game.id)['flags']['missing_audience']
    end

    test 'vollstaendig gezeichnetes Spiel meldet keine fehlenden Angaben' do
      @game.update!(referee1_signed: true, time_keeper_signed: true, record_keeper_signed: true,
                    home_captain_signed: true, guest_captain_signed: true,
                    referee2_string: '123 MUSTER, Max', audience: 120)
      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      flags = row(@game.id)['flags']
      assert_not flags['missing_signatures']
      assert_not flags['missing_referee2']
      assert_not flags['missing_audience']
    end

    test 'ausstehendes Spiel meldet keine fehlenden Angaben' do
      future = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2,
                               date: 30.days.from_now.strftime('%Y-%m-%d'))
      game = create_game(future, game_number: '30')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      flags = row(game.id)['flags']
      assert_not flags['missing_signatures']
      assert_not flags['missing_referee2']
      assert_not flags['missing_audience']
    end

    test 'liegen gebliebener Bericht eines vergangenen Spieltags bleibt auffaellig' do
      past = GameDay.create!(league: @league, arena: @arena, club: @club, number: 3,
                             date: 7.days.ago.strftime('%Y-%m-%d'))
      game = create_game(past, game_number: '31')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      flags = row(game.id)['flags']
      assert flags['missing_signatures']
      assert flags['missing_referee2']
      assert flags['missing_audience']
    end

    test 'vorab gefuehrter Bericht eines kuenftigen Spieltags wird weiter geprueft' do
      future = GameDay.create!(league: @league, arena: @arena, club: @club, number: 4,
                               date: 30.days.from_now.strftime('%Y-%m-%d'))
      game = create_game(future, game_number: '32')
      game.update!(game_status: 'aftergame')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert row(game.id)['flags']['missing_signatures']
    end

    # Die Zone ist die einzige nicht triviale Entscheidung dieser Pruefung, und
    # ohne einen Test an der Grenze liesse sie sich durch Date.today ersetzen,
    # ohne dass etwas rot wird. 23:30 UTC ist in Berlin bereits der Folgetag.
    test 'kurz nach Mitternacht Berliner Zeit zaehlt der Spieltag als heute' do
      travel_to Time.utc(2026, 2, 7, 23, 30) do
        heute = GameDay.create!(league: @league, arena: @arena, club: @club, number: 6,
                                date: '2026-02-08')
        game = create_game(heute, game_number: '34')
        game.update!(start_time: '16:00')

        login(sbk_user(@go.id))
        get OVERVIEW_PATH
        # Anpfiff 16:00 liegt noch vor uns, also keine Mahnung.
        assert_not row(game.id)['flags']['missing_signatures']
      end
    end

    # Der Kern des Fixes: Massgeblich ist der Anpfiff, nicht der Kalendertag.
    # Mit dem Kalendertag trueg ab 00:00 jedes Spiel des laufenden Spieltags
    # wieder alle drei Hinweise.
    test 'am Spieltag vor dem Anpfiff meldet das Spiel nichts' do
      travel_to Time.find_zone!('Europe/Berlin').local(2026, 2, 7, 12, 0) do
        heute = GameDay.create!(league: @league, arena: @arena, club: @club, number: 7,
                                date: '2026-02-07')
        game = create_game(heute, game_number: '35')
        game.update!(start_time: '20:00')

        login(sbk_user(@go.id))
        get OVERVIEW_PATH
        flags = row(game.id)['flags']
        assert_not flags['missing_signatures']
        assert_not flags['missing_referee2']
        assert_not flags['missing_audience']
      end
    end

    # Gegenprobe: Nach dem Anpfiff gehoert der nie begonnene Bericht auf den
    # Tisch der SBK, auch wenn der Spieltag noch laeuft.
    test 'am Spieltag nach dem Anpfiff wird das Spiel wieder auffaellig' do
      travel_to Time.find_zone!('Europe/Berlin').local(2026, 2, 7, 21, 0) do
        heute = GameDay.create!(league: @league, arena: @arena, club: @club, number: 8,
                                date: '2026-02-07')
        game = create_game(heute, game_number: '36')
        game.update!(start_time: '20:00')

        login(sbk_user(@go.id))
        get OVERVIEW_PATH
        assert row(game.id)['flags']['missing_signatures']
      end
    end

    # Ohne Anpfiffzeit ist nicht bekannt, wann das Spiel stattfindet: dann bis
    # Tagesende nicht mahnen.
    test 'ohne Anpfiffzeit gilt der ganze Spieltag als ausstehend' do
      travel_to Time.find_zone!('Europe/Berlin').local(2026, 2, 7, 23, 0) do
        heute = GameDay.create!(league: @league, arena: @arena, club: @club, number: 9,
                                date: '2026-02-07')
        game = create_game(heute, game_number: '37')

        login(sbk_user(@go.id))
        get OVERVIEW_PATH
        assert_not row(game.id)['flags']['missing_signatures']
      end
    end

    test 'unlesbares Spieltagsdatum gilt nicht als Zukunft' do
      broken = GameDay.create!(league: @league, arena: @arena, club: @club, number: 5, date: '')
      game = create_game(broken, game_number: '33')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      assert row(game.id)['flags']['missing_signatures']
    end

    test 'fremder game_operation_id-Filter weitet den eigenen Scope nicht' do
      login(sbk_user(@go.id))
      get OVERVIEW_PATH, params: { game_operation_id: @other_go.id.to_s }
      assert_response :success
      assert_empty body['games']
    end

    test 'Berichtsformular und Ausrichter-Einspruch werden ausgeliefert' do
      uploader = create_user(user_group_id: 6, game_operation_id: 0)
      report = @game.build_game_referee_report(uploaded_by: uploader)
      report.file.attach(io: StringIO.new('PDF'), filename: 'r.pdf', content_type: 'application/pdf')
      report.save!
      @game.update_columns(checklist_veto_submitted_at: Time.current,
                           checklist_veto_answers: [{ 'item_id' => 1, 'answer' => false }])

      login(sbk_user(@go.id))
      get OVERVIEW_PATH
      data = row(@game.id)
      assert data['referee_report']['uploaded_at'].present?
      assert data['checklist_veto_submitted_at'].present?
      assert_equal 1, data['checklist_veto_negative_count']
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
    # Die Ligenliste des Auswahlfelds kommt vom Server und nicht aus den
    # ausgelieferten Zeilen: Bei `truncated` faellt der aelteste Bestand weg,
    # und eine Liga, die nur dort vorkommt, stuende sonst nicht einmal zur
    # Auswahl -- ihr Fehlen waere nicht zu erklaeren.
    test 'die Antwort nennt alle Ligen des Zeitraums' do
      zweite = create(:league, :current_season, game_operation: @go, name: 'Zweite Liga')
      tag = GameDay.create!(league: zweite, arena: @arena, club: @club, number: 20,
                            date: 3.days.ago.strftime('%Y-%m-%d'))
      create_game(tag, game_number: '90')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH

      namen = JSON.parse(response.body)['leagues'].map { |l| l['name'] }
      assert_includes namen, 'Zweite Liga'
      assert_operator namen.size, :>=, 2
    end

    # Und sie bleibt vollstaendig, wenn bereits eine Liga gewaehlt ist. Sonst
    # boete das Feld nach dem ersten Setzen nur noch die eine gewaehlte an.
    test 'die Ligenliste schrumpft nicht durch die Ligaauswahl' do
      zweite = create(:league, :current_season, game_operation: @go, name: 'Zweite Liga')
      tag = GameDay.create!(league: zweite, arena: @arena, club: @club, number: 21,
                            date: 3.days.ago.strftime('%Y-%m-%d'))
      create_game(tag, game_number: '91')

      login(sbk_user(@go.id))
      get OVERVIEW_PATH, params: { league_id: zweite.id }

      body = JSON.parse(response.body)
      assert_operator body['leagues'].size, :>=, 2, 'die Auswahl darf die Liste nicht kuerzen'
      liga_ids = body['games'].map { |g| g['league_id'] }.uniq
      assert_equal [zweite.id], liga_ids, 'die Zeilen selbst sind auf die Liga gefiltert'
    end
  end
end
