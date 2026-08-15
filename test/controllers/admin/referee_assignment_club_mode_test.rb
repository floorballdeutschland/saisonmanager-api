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
      # Ansetzbar sind nur Vereine der Mannschaften dieser Liga.
      @club = create(:club, state_association_id: @sa.id)
      create(:team, league: @league, club: @club)
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

    # Die Anzeige gruppiert nach Spieltag. Ohne Kennung und Nummer im Payload
    # bliebe ihr nur das Datum – zwei Spieltage derselben Liga können aber auf
    # denselben Tag fallen.
    test 'Spieleliste liefert Spieltag-Kennung und -Nummer mit' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      entry = JSON.parse(response.body).find { |g| g['id'] == game.id }
      assert_equal @game_day.id, entry['game_day_id']
      assert_equal @game_day.number, entry['game_day_number']
    end

    # Die RSK arbeitet Liga für Liga und darin Spieltag für Spieltag. Eine rein
    # chronologische Liste mischt die Ligen und zwingt sie, zeilenweise zwischen
    # ihnen zu springen.
    test 'reduzierter Modus sortiert nach Liga und Spieltag statt nach Datum' do
      a_liga = create(:league, game_operation: @go, name: 'A-Liga')
      b_liga = create(:league, game_operation: @go, name: 'B-Liga')

      # Die B-Liga spielt zuerst: chronologisch stünde ihr Spiel ganz oben.
      b_spiel = create(:game, game_status: 'pregame',
                              game_day: create(:game_day, league: b_liga, number: 1,
                                               date: (Date.today + 3).to_s))
      # Spieltagsnummer und Datum zeigen bewusst in verschiedene Richtungen:
      # Spieltag 2 liegt früher als Spieltag 1. Sortierte die Liste innerhalb der
      # Liga nach Datum, kippte die erwartete Reihenfolge.
      a_spiel2 = create(:game, game_status: 'pregame',
                               game_day: create(:game_day, league: a_liga, number: 2,
                                                date: (Date.today + 7).to_s))
      a_spiel1 = create(:game, game_status: 'pregame',
                               game_day: create(:game_day, league: a_liga, number: 1,
                                                date: (Date.today + 21).to_s))
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      ids = JSON.parse(response.body).map { |g| g['id'] }
      assert_equal [a_spiel1.id, a_spiel2.id, b_spiel.id], ids
    end

    # Innerhalb des Spieltags schaut die RSK am längsten auf diese Tabelle; das
    # Frontend sortiert dort selbst nichts, sondern übernimmt die Reihenfolge.
    # `start_time` ist eine Textspalte, eine leere Zeit muss ans Ende und nicht
    # an den Anfang.
    test 'innerhalb des Spieltags nach Anwurf, Spiele ohne Anwurf zuletzt' do
      ohne_zeit = create(:game, game_day: @game_day, game_status: 'pregame',
                                start_time: '', game_number: '3')
      spaet = create(:game, game_day: @game_day, game_status: 'pregame',
                            start_time: '16:00', game_number: '2')
      frueh = create(:game, game_day: @game_day, game_status: 'pregame',
                            start_time: '10:00', game_number: '1')
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      ids = JSON.parse(response.body).map { |g| g['id'] }
      assert_equal [frueh.id, spaet.id, ohne_zeit.id], ids
    end

    # K.-o.-Runden vergeben nicht-numerische Spielnummern („HF1", „FIN"). Der
    # Gleichstands-Schlüssel darf daran nicht die ganze Abfrage abbrechen.
    test 'nicht-numerische Spielnummern brechen die Sortierung nicht ab' do
      create(:game, game_day: @game_day, game_status: 'pregame',
                    start_time: '10:00', game_number: 'HF1')
      create(:game, game_day: @game_day, game_status: 'pregame',
                    start_time: '10:00', game_number: '7')
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      assert_equal 2, JSON.parse(response.body).size
    end

    # Ligen verschiedener Verbände heißen oft gleich. Ohne den Verband im Payload
    # wären sie in der Ligaauswahl nicht zu unterscheiden.
    test 'Spieleliste nennt den Spielbetrieb der Liga' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      assert_response :success
      entry = JSON.parse(response.body).find { |g| g['id'] == game.id }
      assert_equal(@go.short_name.presence || @go.name, entry['game_operation'])
    end

    test 'Verein ansetzen steht sofort im Spielplan und verschickt keine Mail' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      club = @club
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
      club = @club
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
      club = @club
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

    # Der Personen-Weg überschreibt beim Veröffentlichen den Freitext mit den
    # Schiedsrichter-Namen – der alte Sentinel war danach weg. Die Migration
    # konnte solche Spiele nicht erkennen, sie stehen mit
    # person_level_assignment = false im Bestand. Schaltet ein Verband später auf
    # den reduzierten Modus, dürfen sie hier trotzdem nicht bearbeitbar sein:
    # sonst würfe ein Freitext-Eintrag die bereits benachrichtigten
    # Schiedsrichter kommentarlos aus dem Spiel.
    test 'Spiel mit angesetztem Gespann ist gesperrt, auch ohne Markierung' do
      game = create(:game, game_day: @game_day, game_status: 'pregame', person_level_assignment: false)
      referee = create(:referee, club_id: create(:club, state_association_id: @sa.id).id)
      assignment = RefereeAssignment.create!(game: game, referee1: referee, status: 'published')
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'
      assert_response :success
      row = JSON.parse(response.body).find { |g| g['id'] == game.id }
      assert_equal true, row['locked']

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { nominated_referee_string: 'Müller / Schmidt' }

      assert_response :unprocessable_entity
      assert RefereeAssignment.exists?(assignment.id)
      assert_equal referee.id, assignment.reload.referee1_id
    end

    test 'begonnenes Spiel laesst sich nicht mehr umschreiben' do
      game = create(:game, game_day: @game_day, game_status: 'pregame', started: true,
                           nominated_referee_string: 'Meier / Krause')
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { nominated_referee_string: 'Jemand anderes' }

      assert_response :unprocessable_entity
      assert_equal 'Meier / Krause', game.reload.nominated_referee_string
    end

    # club_id kam ungeprüft aus den Parametern: der Name landet öffentlich im
    # Spielplan, und die club_id ist der Anker für die spätere Selbstbenennung.
    test 'Verein ausserhalb der Liga wird nicht angesetzt' do
      game = create(:game, game_day: @game_day, game_status: 'pregame')
      fremd = create(:club, state_association_id: @sa.id)
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{game.id}/club_assignment",
            params: { club_id: fremd.id }

      assert_response :not_found
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
