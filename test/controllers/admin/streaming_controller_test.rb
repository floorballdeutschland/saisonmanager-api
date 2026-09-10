require 'test_helper'

module Admin
  # Der Abruf liefert den Streamschlüssel im Klartext -- er ist das Geheimnis,
  # mit dem man auf den Verbandskanal sendet. Entsprechend steht hier zu jedem
  # erlaubten Zugang die Gegenprobe, wer ihn NICHT bekommt.
  class StreamingControllerTest < ActionDispatch::IntegrationTest
    STREAM_KEY = 'abcd-efgh-ijkl-mnop-qrst'.freeze

    setup do
      create(:setting)
      @sa = create(:state_association)
      @go = create(:game_operation, state_association_id: @sa.id)
      @league = create(:league, game_operation: @go, name: '1. FBL Herren',
                                stream_playlist: '1. Floorball-Bundesliga Herren 26/27')
      @club = create(:club)
      @arena = create(:arena, name: 'Sporthalle Dösner Weg')
      @game_day = GameDay.create!(league: @league, arena: @arena, club: @club,
                                  number: 1, date: '2026-09-12')
      @home = create(:team, league: @league, club: @club, name: 'MFBC Leipzig', stream_key: STREAM_KEY)
      @guest = create(:team, league: @league, club: create(:club), name: 'Floor Fighters Chemnitz')
      @game = create_game('18:00')
    end

    # --- Rechte ---------------------------------------------------------------

    test 'Admin bekommt die Liste samt Streamschlüssel' do
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_response :success
      eintrag = response.parsed_body.first
      assert_equal @game.id, eintrag['id']
      assert_equal STREAM_KEY, eintrag['stream_key']
      assert eintrag['streamable']
    end

    test 'global gescopte FD-SBK bekommt die Liste' do
      login(create(:user, :sbk_global))

      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_response :success
    end

    test 'GEGENPROBE: regionale SBK bekommt nichts' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_response :forbidden
    end

    test 'GEGENPROBE: ohne Anmeldung kein Zugriff' do
      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_response :unauthorized
    end

    # --- Zuschnitt ------------------------------------------------------------

    test 'Spieltag einer Liga liefert alle Hallen dieser Nummer' do
      zweite_halle = GameDay.create!(league: @league, arena: create(:arena), club: create(:club),
                                     number: 1, date: '2026-09-13')
      zweites = Game.create!(game_day: zweite_halle, home_team: @guest, guest_team: @home,
                             start_time: '15:00', forfait: 0, overtime: false, legacy: false,
                             events: [], players: { 'home' => [], 'guest' => [] })
      # Andere Nummer -- darf nicht mitkommen.
      anderer = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-09-19')
      Game.create!(game_day: anderer, home_team: @home, guest_team: @guest,
                   start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                   events: [], players: { 'home' => [], 'guest' => [] })
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games',
          params: { league_id: @league.id, game_day_number: 1 }

      assert_response :success
      assert_equal [@game.id, zweites.id].sort, response.parsed_body.map { |e| e['id'] }.sort
    end

    test 'der Zeitraum zeigt nur Ligen, in denen gestreamt wird' do
      fremde_liga = create(:league, game_operation: @go, name: 'Landesliga')
      fremder_spieltag = GameDay.create!(league: fremde_liga, arena: @arena, club: create(:club),
                                         number: 1, date: '2026-09-12')
      Game.create!(game_day: fremder_spieltag,
                   home_team: create(:team, league: fremde_liga, club: create(:club)),
                   guest_team: create(:team, league: fremde_liga, club: create(:club)),
                   start_time: '18:00', forfait: 0, overtime: false, legacy: false,
                   events: [], players: { 'home' => [], 'guest' => [] })
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_response :success
      assert_equal [@game.id], response.parsed_body.map { |e| e['id'] }.to_a
    end

    test 'die Liste ist nach Anwurf sortiert' do
      frueher = Game.create!(game_day: @game_day, home_team: @guest, guest_team: @home,
                             start_time: '14:00', forfait: 0, overtime: false, legacy: false,
                             events: [], players: { 'home' => [], 'guest' => [] })
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { from: '2026-09-12', to: '2026-09-14' }

      assert_equal [frueher.id, @game.id], response.parsed_body.map { |e| e['id'] }.to_a
    end

    test 'zu breiter Zeitraum wird abgelehnt statt beantwortet' do
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { from: '2026-01-01', to: '2026-12-31' }

      assert_response :bad_request
    end

    test 'unbrauchbares Datum ist ein Eingabefehler, kein Serverfehler' do
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { from: 'gestern', to: 'morgen' }

      assert_response :bad_request
    end

    test 'ohne Zuschnitt sagt der Abruf, was fehlt' do
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games'

      assert_response :bad_request
    end

    # --- Der Schlüssel gehört dem Ausrichter ----------------------------------

    test 'der Schluessel kommt vom Ausrichter, nicht von der Heimmannschaft' do
      # Ausrichter @club stellt den Schlüssel; gespielt wird zwischen zwei
      # anderen Mannschaften.
      fremd = Game.create!(game_day: @game_day,
                           home_team: create(:team, league: @league, club: create(:club)),
                           guest_team: create(:team, league: @league, club: create(:club)),
                           start_time: '20:00', forfait: 0, overtime: false, legacy: false,
                           events: [], players: { 'home' => [], 'guest' => [] })
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { league_id: @league.id, game_day_number: 1 }

      eintrag = response.parsed_body.find { |e| e['id'] == fremd.id }
      assert_equal STREAM_KEY, eintrag['stream_key']
    end

    test 'ohne Schluessel am Ausrichter ist das Spiel nicht streambar' do
      @home.update!(stream_key: nil)
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/games', params: { league_id: @league.id, game_day_number: 1 }

      eintrag = response.parsed_body.first
      assert_nil eintrag['stream_key']
      assert_not eintrag['streamable']
    end

    # --- Rückmeldung einer angelegten Übertragung -----------------------------

    test 'meldet eine angelegte Uebertragung zurueck und schreibt den Link ins Spiel' do
      login(create(:user, :admin))

      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
           params: { broadcast_id: 'yt-123', privacy_status: 'public', title: 'MFBC vs FFC' }

      assert_response :created
      satz = StreamBroadcast.find_by(broadcast_id: 'yt-123')
      assert_equal @game.id, satz.game_id
      assert_equal 'https://www.youtube.com/watch?v=yt-123', @game.reload.live_stream_link
    end

    test 'GEGENPROBE: eine nicht-oeffentliche Uebertragung landet nicht im Spielplan' do
      # Der Verein sendet parallel auf seinen eigenen Kanal; unser Mitschnitt ist
      # dann oft ungelistet. Ein solcher Link wäre für Zuschauer tot.
      login(create(:user, :admin))

      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
           params: { broadcast_id: 'yt-123', privacy_status: 'unlisted' }

      assert_response :created
      assert_not_nil StreamBroadcast.find_by(broadcast_id: 'yt-123')
      assert_nil @game.reload.live_stream_link
    end

    test 'GEGENPROBE: ein vorhandener Link des Vereins wird nicht ueberschrieben' do
      @game.update!(live_stream_link: 'https://www.youtube.com/watch?v=verein')
      login(create(:user, :admin))

      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
           params: { broadcast_id: 'yt-123', privacy_status: 'public' }

      assert_equal 'https://www.youtube.com/watch?v=verein', @game.reload.live_stream_link
    end

    test 'zweimal dieselbe Uebertragung melden legt keinen zweiten Satz an' do
      login(create(:user, :admin))

      2.times do
        post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
             params: { broadcast_id: 'yt-123', privacy_status: 'public' }
      end

      assert_equal 1, StreamBroadcast.where(broadcast_id: 'yt-123').count
    end

    test 'eine gemeldete Uebertragung steht danach in der Liste' do
      login(create(:user, :admin))
      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
           params: { broadcast_id: 'yt-123', privacy_status: 'public' }

      get '/api/v2/admin/streaming/games', params: { league_id: @league.id, game_day_number: 1 }

      broadcast = response.parsed_body.first['broadcast']
      assert_equal 'yt-123', broadcast['broadcast_id']
      assert_equal 'https://www.youtube.com/watch?v=yt-123', broadcast['watch_url']
    end

    test 'GEGENPROBE: regionale SBK darf nichts zurueckmelden' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast",
           params: { broadcast_id: 'yt-123', privacy_status: 'public' }

      assert_response :forbidden
      assert_nil StreamBroadcast.find_by(broadcast_id: 'yt-123')
    end

    test 'ohne broadcast_id wird nichts angelegt' do
      login(create(:user, :admin))

      post "/api/v2/admin/streaming/games/#{@game.id}/broadcast", params: { privacy_status: 'public' }

      assert_response :bad_request
      assert_nil @game.reload.live_stream_link
    end

    test 'unbekanntes Spiel meldet nicht gefunden' do
      login(create(:user, :admin))

      post '/api/v2/admin/streaming/games/999999/broadcast',
           params: { broadcast_id: 'yt-123', privacy_status: 'public' }

      assert_response :not_found
    end

    # --- Vorlagen -------------------------------------------------------------

    test 'liefert die Vorgabevorlagen, solange nichts gepflegt ist' do
      login(create(:user, :admin))

      get '/api/v2/admin/streaming/settings'

      assert_response :success
      body = response.parsed_body
      assert_equal Setting::DEFAULT_STREAM_TITLE, body['title']
      assert_equal Setting::DEFAULT_STREAM_TITLE, body['default_title']
      assert_includes body['description'], '{heim}'
    end

    test 'speichert eigene Vorlagen' do
      login(create(:user, :admin))

      put '/api/v2/admin/streaming/settings',
          params: { title: '{liga}: {heim} – {gast}', description: 'Anwurf {uhrzeit}' }

      assert_response :success
      assert_equal '{liga}: {heim} – {gast}', Setting.stream_title_template
      assert_equal 'Anwurf {uhrzeit}', Setting.stream_description_template
    end

    # Ein leeres Feld ist der naheliegende Weg, eine verunglückte Vorlage
    # loszuwerden -- ein Stream ohne Titel wäre bei YouTube namenlos.
    test 'eine geleerte Vorlage faellt auf die Vorgabe zurueck' do
      login(create(:user, :admin))
      put '/api/v2/admin/streaming/settings', params: { title: 'Eigen', description: 'Eigen' }
      assert_equal 'Eigen', Setting.stream_title_template

      put '/api/v2/admin/streaming/settings', params: { title: '   ', description: '' }

      assert_response :success
      assert_equal Setting::DEFAULT_STREAM_TITLE, Setting.stream_title_template
      assert_equal Setting::DEFAULT_STREAM_DESCRIPTION, Setting.stream_description_template
    end

    test 'GEGENPROBE: regionale SBK darf die Vorlagen nicht aendern' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      put '/api/v2/admin/streaming/settings', params: { title: 'Fremd' }

      assert_response :forbidden
      assert_equal Setting::DEFAULT_STREAM_TITLE, Setting.stream_title_template
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def create_game(start_time)
      Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                   start_time: start_time, forfait: 0, overtime: false, legacy: false,
                   events: [], players: { 'home' => [], 'guest' => [] })
    end
  end
end
