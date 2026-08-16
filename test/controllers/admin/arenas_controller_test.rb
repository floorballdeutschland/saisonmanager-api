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

    test 'Bearbeiten reaktiviert einen bewusst deaktivierten Spielort nicht' do
      arena = create(:arena, active: false)
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{arena.id}", params: { name: 'Umbenannt', city: arena.city }

      assert_response :success
      refute arena.reload.active
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
