require 'test_helper'

module Admin
  class ArenasControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @arena = create(:arena)
    end

    test 'SBK darf einen Spielort weiterhin bearbeiten' do
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{@arena.id}", params: { name: 'Neue Halle', city: @arena.city }

      assert_response :success
      assert_equal 'Neue Halle', @arena.reload.name
    end

    test 'Regionale SBK darf einen Spielort nicht löschen' do
      login(create(:user, :sbk_scoped))

      assert_no_difference -> { Arena.count } do
        delete "/api/v2/admin/arenas/#{@arena.id}"
      end

      assert_response :forbidden
    end

    test 'Regionale SBK darf Spielorte nicht zusammenführen' do
      secondary = create(:arena)
      login(create(:user, :sbk_scoped))

      assert_no_difference -> { Arena.count } do
        post "/api/v2/admin/arenas/#{@arena.id}/merge", params: { secondary_id: secondary.id }
      end

      assert_response :forbidden
    end

    test 'Global gescopte FD-SBK darf einen Spielort löschen' do
      login(create(:user, :sbk_global))

      assert_difference -> { Arena.count }, -1 do
        delete "/api/v2/admin/arenas/#{@arena.id}"
      end

      assert_response :no_content
    end

    test 'Global gescopte FD-SBK darf Spielorte zusammenführen' do
      secondary = create(:arena)
      login(create(:user, :sbk_global))

      post "/api/v2/admin/arenas/#{@arena.id}/merge", params: { secondary_id: secondary.id }

      assert_response :success
      assert_nil Arena.find_by(id: secondary.id)
    end

    test 'Admin darf einen Spielort löschen' do
      login(create(:user, :admin))

      assert_difference -> { Arena.count }, -1 do
        delete "/api/v2/admin/arenas/#{@arena.id}"
      end

      assert_response :no_content
    end

    test 'Admin darf Spielorte zusammenführen' do
      secondary = create(:arena)
      login(create(:user, :admin))

      post "/api/v2/admin/arenas/#{@arena.id}/merge", params: { secondary_id: secondary.id }

      assert_response :success
      assert_nil Arena.find_by(id: secondary.id)
    end

    # Der Spaltendefault von arenas.active ist false, der Spielplan bietet über
    # Arena.active aber nur aktive Spielorte an. Ein neu angelegter Spielort stand
    # deshalb in der Stammdatenliste, fehlte im Spieltag-Dropdown aber komplett (#449).
    test 'Ein neu angelegter Spielort ist aktiv' do
      login(create(:user, :sbk_scoped))

      post '/api/v2/admin/arenas', params: { name: 'Gymnasium-Halle Puchheim', city: 'Puchheim' }

      assert_response :created
      arena = Arena.find_by(name: 'Gymnasium-Halle Puchheim')
      assert arena.active, 'Spielort wurde inaktiv angelegt'
      assert_includes Arena.active, arena
    end

    test 'Auch ein per force angelegter Dublettenspielort ist aktiv' do
      create(:arena, name: 'Gymnasium-Halle Puchheim', city: 'Puchheim')
      login(create(:user, :sbk_scoped))

      post '/api/v2/admin/arenas',
           params: { name: 'Gymnasium-Halle Puchheim', city: 'Puchheim', force: true }

      assert_response :created
      assert Arena.where(city: 'Puchheim').order(:id).last.active
    end

    # Regression auf die eigentliche Meldung: der Weg vom Anlegen bis in die
    # Spielplanverwaltung. additional_references filtert auf Arena.active.
    test 'Ein neu angelegter Spielort steht im Spielplan zur Auswahl' do
      league = create(:league)
      login(create(:user, :admin))

      post '/api/v2/admin/arenas', params: { name: 'Gymnasium-Halle Puchheim', city: 'Puchheim' }
      assert_response :created

      get "/api/v2/admin/leagues/#{league.id}/additional_references"

      assert_response :success
      names = JSON.parse(response.body)['arenas'].map { |a| a['name'] }
      assert_includes names, 'Gymnasium-Halle Puchheim'
    end

    # Der naheliegende Aufräumweg nach dieser Änderung: den fehlenden Spielort neu
    # anlegen und danach in den alten Eintrag zusammenführen, der die Spieltage
    # trägt. Bliebe der verbleibende Eintrag inaktiv, wäre man wieder am Anfang.
    test 'Zusammenführen macht einen inaktiven Ziel-Spielort auswaehlbar' do
      master = create(:arena, active: false)
      secondary = create(:arena)
      login(create(:user, :admin))

      post "/api/v2/admin/arenas/#{master.id}/merge", params: { secondary_id: secondary.id }

      assert_response :success
      assert master.reload.active
      assert_equal true, JSON.parse(response.body)['master']['active']
    end

    test 'Zusammenführen gelingt auch bei einem Ziel-Spielort ohne Ort' do
      master = create(:arena, active: false)
      master.update_columns(city: nil)
      secondary = create(:arena)
      game_day = create(:game_day, arena: secondary)
      login(create(:user, :admin))

      post "/api/v2/admin/arenas/#{master.id}/merge", params: { secondary_id: secondary.id }

      assert_response :success
      assert master.reload.active
      assert_equal master.id, game_day.reload.arena_id
    end

    # Erst mit dem erlaubten `active` ist POST mit `active: false` überhaupt
    # erreichbar. Die Zusicherung aus #449 hängt daran, dass create den Wert
    # nach arena_params setzt und nicht davor.
    test 'Ein neu angelegter Spielort ist auch mit active false aktiv' do
      login(create(:user, :sbk_scoped))

      post '/api/v2/admin/arenas',
           params: { name: 'Gymnasium-Halle Puchheim', city: 'Puchheim', active: false }

      assert_response :created
      assert Arena.find_by(name: 'Gymnasium-Halle Puchheim').active
    end

    # #451: `active` war über keine Maske erreichbar. Damit die Verwaltung den
    # Zustand überhaupt anzeigen kann, muss er in der Liste mitkommen.
    test 'Die Spielortliste liefert den Aktiv-Zustand mit' do
      inactive = create(:arena, active: false)
      login(create(:user, :sbk_scoped))

      get '/api/v2/admin/arenas'

      assert_response :success
      by_id = JSON.parse(response.body).index_by { |a| a['id'] }
      assert_equal true, by_id[@arena.id]['active']
      assert_equal false, by_id[inactive.id]['active']
    end

    test 'SBK darf einen inaktiven Spielort wieder aktivieren' do
      arena = create(:arena, active: false)
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{arena.id}",
          params: { name: arena.name, city: arena.city, active: true }

      assert_response :success
      assert arena.reload.active
      assert_equal true, JSON.parse(response.body)['active']
    end

    test 'SBK darf einen Spielort deaktivieren' do
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{@arena.id}",
          params: { name: @arena.name, city: @arena.city, active: false }

      assert_response :success
      assert_not @arena.reload.active
    end

    test 'Admin darf einen inaktiven Spielort wieder aktivieren' do
      arena = create(:arena, active: false)
      login(create(:user, :admin))

      put "/api/v2/admin/arenas/#{arena.id}",
          params: { name: arena.name, city: arena.city, active: true }

      assert_response :success
      assert arena.reload.active
    end

    # Der Zustand bleibt stehen, wenn eine Maske ihn gar nicht mitschickt –
    # sonst würde jedes Umbenennen einen Spielort stillschweigend deaktivieren.
    test 'Ein Update ohne active laesst den Zustand unveraendert' do
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{@arena.id}", params: { name: 'Neue Halle', city: @arena.city }

      assert_response :success
      assert @arena.reload.active
    end

    # Regression auf die eigentliche Meldung aus #451: der Weg vom Aktivieren
    # bis in die Spielplanverwaltung. additional_references filtert auf Arena.active.
    test 'Ein wieder aktivierter Spielort steht im Spielplan zur Auswahl' do
      league = create(:league)
      arena = create(:arena, name: 'Gymnasium-Halle Puchheim', city: 'Puchheim', active: false)
      login(create(:user, :admin))

      get "/api/v2/admin/leagues/#{league.id}/additional_references"
      assert_response :success
      assert_not_includes JSON.parse(response.body)['arenas'].map { |a| a['name'] }, 'Gymnasium-Halle Puchheim'

      put "/api/v2/admin/arenas/#{arena.id}",
          params: { name: arena.name, city: arena.city, active: true }
      assert_response :success

      get "/api/v2/admin/leagues/#{league.id}/additional_references"

      assert_response :success
      names = JSON.parse(response.body)['arenas'].map { |a| a['name'] }
      assert_includes names, 'Gymnasium-Halle Puchheim'
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
