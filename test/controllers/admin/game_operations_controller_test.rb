require 'test_helper'

module Admin
  # Spielbetriebe ueber die Oberflaeche pflegen (Issue #492). Nur bundesweite
  # Admins: An einem Spielbetrieb haengen zwei Felder, die Rechte verschieben --
  # `state_association_id` (Zustaendigkeit fuer einen ganzen Verbandsbaum) und
  # `national` (hebt SBK/RSK/Ansetzer auf globalen Scope).
  class GameOperationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @sa = create(:state_association, name: 'LV Ziel')
      @go = create(:game_operation, state_association_id: @sa.id, path: 'ziel')
    end

    test 'Admin liest, legt an, aendert und loescht' do
      login(@admin)

      get "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'ziel', body['path']
      assert_equal 'LV Ziel', body['state_association_name']
      assert_equal false, body['national']

      neuer_lv = create(:state_association, name: 'LV Neu')
      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Floorball Bund Hamburg', short_name: 'FBH',
                                       path: 'fbh', state_association_id: neuer_lv.id } }
      assert_response :created
      neu = GameOperation.find(JSON.parse(response.body)['id'])
      assert_equal 'fbh', neu.path
      assert_equal neuer_lv.id, neu.state_association_id

      put "/api/v2/admin/game_operations/#{neu.id}",
          params: { game_operation: { name: 'FBH', short_name: 'FBH', path: 'hamburg',
                                      state_association_id: neuer_lv.id } }
      assert_response :success
      assert_equal 'hamburg', neu.reload.path

      delete "/api/v2/admin/game_operations/#{neu.id}"
      assert_response :no_content
      assert_nil GameOperation.find_by(id: neu.id)
    end

    # Der neue Spielbetrieb steckt in /api/v2/init, das der Endpunkt 30 Minuten
    # zwischenspeichert. Ohne Leerung fehlt er eine halbe Stunde in jeder
    # Auswahl -- und dann sucht niemand mehr beim Anlegen, sondern beim Cache.
    test 'Anlegen leert den init-Cache' do
      with_real_cache do
        Rails.cache.write('settings/init', { alt: true })
        login(@admin)

        post '/api/v2/admin/game_operations',
             params: { game_operation: { name: 'Cache-Verband', short_name: 'CVB', path: 'cvb',
                                         state_association_id: create(:state_association).id } }
        assert_response :created

        assert_nil Rails.cache.read('settings/init')
      end
    end

    test 'ein regional gescopter Admin bekommt 403, auch beim Lesen' do
      regional = create(:user, permissions: [{ 'user_group_id' => 1, 'game_operation_id' => @go.id }])
      login(regional)

      get "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :forbidden

      put "/api/v2/admin/game_operations/#{@go.id}",
          params: { game_operation: { name: 'Uebernommen' } }
      assert_response :forbidden
      assert_not_equal 'Uebernommen', @go.reload.name
    end

    # Issue #492 nennt ausdruecklich „Nur fuer Admin, nicht fuer SBK". Der global
    # gescopte SBK darf die Landesverbaende verwalten (dort reicht
    # global_state_association_manager?), Spielbetriebe aber nicht.
    test 'globaler SBK darf keine Spielbetriebe anlegen' do
      login(create(:user, :sbk_global))

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'SBK-Verband', short_name: 'SVB', path: 'svb' } }
      assert_response :forbidden
      assert_nil GameOperation.find_by(path: 'svb')
    end

    test 'ohne Anmeldung 401' do
      get "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :unauthorized
    end

    test 'unbekannte ID gibt 404' do
      login(@admin)

      get '/api/v2/admin/game_operations/999999'
      assert_response :not_found
    end

    # Ein zweiter Spielbetrieb an einem Landesverband ist angelegt, sichtbar und
    # wirkungslos: GameOperation.id_by_state_association behaelt den mit der
    # niedrigeren ID. Ohne die Pruefung faellt das erst auf, wenn die Vereine
    # ausbleiben.
    test 'zweiter Spielbetrieb am selben Landesverband wird abgelehnt' do
      login(@admin)

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Zweiter', short_name: 'ZWT', path: 'zwt',
                                       state_association_id: @sa.id } }
      assert_response :unprocessable_entity
      assert_match(/bereits einen Spielbetrieb/, JSON.parse(response.body)['errors'].join)
    end

    test 'belegter Pfad und Grossschreibung' do
      login(@admin)

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Pfad-Dublette', short_name: 'PDB', path: 'ZIEL',
                                       state_association_id: create(:state_association).id } }
      assert_response :unprocessable_entity,
                      'ZIEL und ziel sind derselbe Pfad -- der Vergleich darf nicht auf Schreibweise hereinfallen'
    end

    # Der Pfad wird das erste Segment der oeffentlichen Adresse. Die Auffangroute
    # ':association' steht im Frontend als letzte, ein belegtes Segment ergibt
    # also keine Fehlermeldung, sondern eine unerreichbare Verbandsseite.
    test 'ein vom Frontend belegter Pfad wird abgelehnt' do
      login(@admin)

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Kollision', short_name: 'KOL', path: 'verwaltung',
                                       state_association_id: create(:state_association).id } }
      assert_response :unprocessable_entity
      assert_match(/unerreichbare Verbandsseite/, JSON.parse(response.body)['errors'].join)
    end

    test 'Umlaute und Leerzeichen im Pfad werden abgelehnt statt abgeleitet' do
      login(@admin)

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Umlaut', short_name: 'UML', path: 'süd west',
                                       state_association_id: create(:state_association).id } }
      assert_response :unprocessable_entity
      assert_nil GameOperation.find_by(name: 'Umlaut')
    end

    # Ohne Pfad leitet das Modell aus dem Kuerzel ab. Der abgeleitete Wert muss in
    # der Spalte landen, nicht nur in #slug: `by_shortname` sucht ausschliesslich
    # in `path`, und ein nur berechneter Slug fuehrte auf eine Adresse, unter der
    # der Endpunkt den Spielbetrieb nicht findet.
    test 'ohne Pfad wird er aus dem Kuerzel abgeleitet und gespeichert' do
      login(@admin)

      post '/api/v2/admin/game_operations',
           params: { game_operation: { name: 'Ohne Pfad', short_name: 'SBK Nord',
                                       state_association_id: create(:state_association).id } }
      assert_response :created
      neu = GameOperation.find(JSON.parse(response.body)['id'])
      assert_equal 'sbk-nord', neu.path
      assert_equal neu.path, neu.slug

      get "/game_operations/by_shortname/#{neu.path}", headers: api_key_header
      assert_response :success
      assert_equal neu.id, JSON.parse(response.body)['id']
    end

    test 'national ist ueber die Maske setzbar' do
      login(@admin)

      put "/api/v2/admin/game_operations/#{@go.id}",
          params: { game_operation: { name: @go.name, short_name: @go.short_name,
                                      path: @go.path, national: true } }
      assert_response :success
      assert @go.reload.national

      # Gegenprobe: Der Schalter wirkt, ein SBK dieses Spielbetriebs ist jetzt global.
      sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
      assert_includes sbk.permission_hash[:sbk], 0
    end

    # Auf leagues.game_operation_id liegt kein Fremdschluessel und kein
    # `dependent:`. Ohne Riegel verlieren die Ligen ihren Verband, und
    # League#game_operation ist an Dutzenden Stellen die Quelle der
    # game_operation_id in der Rechtepruefung.
    test 'Loeschen ist blockiert, solange Ligen daran haengen' do
      create(:league, game_operation: @go)
      login(@admin)

      delete "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :unprocessable_entity
      assert_match(/Liga/, JSON.parse(response.body)['errors'].join)
      assert GameOperation.exists?(@go.id)
    end

    # Vereine haengen nicht per Spalte am Spielbetrieb, sondern abgeleitet
    # (Club#main_game_operation_id). Genau deshalb faellt das Loeschen lautlos
    # aus: Sie waeren danach nur noch fuer die Bundesebene sichtbar.
    test 'Loeschen ist blockiert, solange Vereine zustaendig sind' do
      create(:club, state_association_id: @sa.id)
      login(@admin)

      delete "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :unprocessable_entity
      assert_match(/Verein/, JSON.parse(response.body)['errors'].join)
      assert GameOperation.exists?(@go.id)
    end

    # `users.permissions` ist JSONB ohne Fremdschluessel. Die Rolle zeigte nach
    # dem Loeschen auf eine ID, die es nicht mehr gibt -- der Nutzer behielte
    # seinen Menuepunkt und saehe nichts mehr.
    test 'Loeschen ist blockiert, solange Benutzerrollen darauf verweisen' do
      create(:user, :sbk_scoped, game_operation_id: @go.id)
      login(@admin)

      delete "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :unprocessable_entity
      assert_match(/Benutzerrolle/, JSON.parse(response.body)['errors'].join)
      assert GameOperation.exists?(@go.id)
    end

    # Altbestand traegt die game_operation_id teils als String. jsonb-Containment
    # ist typstreng und findet die Variante nicht -- bei einer Loeschpruefung der
    # schlimmere Fehler von beiden, weil der Riegel dann gar nicht greift.
    test 'der Riegel greift auch bei einer game_operation_id als String' do
      create(:user, permissions: [{ 'user_group_id' => 2, 'game_operation_id' => @go.id.to_s }])
      login(@admin)

      delete "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :unprocessable_entity
      assert_match(/Benutzerrolle/, JSON.parse(response.body)['errors'].join)
    end

    test 'ein Spielbetrieb ohne Anhang laesst sich loeschen' do
      login(@admin)

      delete "/api/v2/admin/game_operations/#{@go.id}"
      assert_response :no_content
    end

    # Zustaendig ist immer der Spielbetrieb der WURZEL des Verbandsbaums
    # (Club#main_game_operation_id). Ein Umhaengen auf einen untergeordneten
    # Verband liesse den Spielbetrieb ohne Vereine zurueck, ohne dass an der
    # Maske etwas davon zu sehen waere.
    test 'Umhaengen auf einen untergeordneten Landesverband wird abgelehnt' do
      create(:club, state_association_id: @sa.id)
      verbund = create(:state_association)
      kind = create(:state_association, parent: verbund)
      login(@admin)

      put "/api/v2/admin/game_operations/#{@go.id}",
          params: { game_operation: { name: @go.name, short_name: @go.short_name,
                                      path: @go.path, state_association_id: kind.id } }
      assert_response :unprocessable_entity
      assert_match(/uebergeordneten Verbund|übergeordneten Verbund/, JSON.parse(response.body)['errors'].join)
      assert_equal @sa.id, @go.reload.state_association_id
    end

    test 'das Feld leeren wird abgelehnt, solange Vereine zustaendig sind' do
      create(:club, state_association_id: @sa.id)
      login(@admin)

      put "/api/v2/admin/game_operations/#{@go.id}",
          params: { game_operation: { name: @go.name, short_name: @go.short_name,
                                      path: @go.path, state_association_id: '' } }
      assert_response :unprocessable_entity
      assert_equal @sa.id, @go.reload.state_association_id
    end

    # Gegenprobe: Ohne zustaendige Vereine ist das Umhaengen unbedenklich, und der
    # Riegel darf es nicht trotzdem verweigern.
    test 'Umhaengen ohne zustaendige Vereine ist erlaubt' do
      ziel = create(:state_association)
      login(@admin)

      put "/api/v2/admin/game_operations/#{@go.id}",
          params: { game_operation: { name: @go.name, short_name: @go.short_name,
                                      path: @go.path, state_association_id: ziel.id } }
      assert_response :success
      assert_equal ziel.id, @go.reload.state_association_id
    end

    test 'Pflichtfelder' do
      login(@admin)

      post '/api/v2/admin/game_operations', params: { game_operation: { path: 'ohne-namen' } }
      assert_response :unprocessable_entity
      fehler = JSON.parse(response.body)['errors'].join
      assert_match(/Name/, fehler)
      assert_match(/Short name/, fehler)
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Der Klartext-Key wird nie gespeichert, ApiKey.generate gibt ihn einmal zurueck.
    def api_key_header
      key, = ApiKey.generate(name: 'Test')
      { 'X-Api-Key' => key }
    end
  end
end
