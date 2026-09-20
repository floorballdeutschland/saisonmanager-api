require 'test_helper'

module Admin
  class SettingsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @setting = create(:setting, current_season_id: '17')
      @admin = create_user(user_group_id: 1, game_operation_id: 0)
      @vm    = create_user(user_group_id: 4, game_operation_id: 0)
    end

    test 'Admin erstellt Saison mit gültigem Namen → 201 mit min_league_id und min_team_id' do
      login(@admin)
      post '/api/v2/admin/settings/seasons', params: { name: 'Saison 2026/27' }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'Saison 2026/27', body['name']
      assert body.key?('id')
      assert body.key?('min_league_id')
      assert body.key?('min_team_id')
      assert_equal false, body['current']
    end

    test 'Leerer Name → 422' do
      login(@admin)
      post '/api/v2/admin/settings/seasons', params: { name: '' }
      assert_response :unprocessable_entity
    end

    test 'VM versucht Saison anzulegen → 403' do
      login(@vm)
      post '/api/v2/admin/settings/seasons', params: { name: 'Saison 2026/27' }
      assert_response :forbidden
    end

    test 'Admin aktiviert existierende Saison → 200 mit neuer current_season_id' do
      login(@admin)
      patch '/api/v2/admin/settings/current_season', params: { season_id: 18 }
      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal 18, body['current_season_id']
    end

    # Der Wechsel schliesst zugleich die offenen Berichte der Vorsaisons: Sonst
    # bliebe ein am Saisonende offen gebliebener Bericht dauerhaft bearbeitbar,
    # beim ausrichtenden Verein auch Jahre spaeter noch.
    test 'Admin aktiviert Saison → offene Berichte der Vorsaisons werden geschlossen' do
      alte_liga = create(:league, season_id: '17')
      altes_spiel = spiel_in(alte_liga, status: 'aftergame')
      neue_liga = create(:league, season_id: '18')
      neues_spiel = spiel_in(neue_liga, status: 'aftergame')

      login(@admin)
      patch '/api/v2/admin/settings/current_season', params: { season_id: 18 }

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal 1, body['closed_reports']
      assert_equal 1, body['closed_report_leagues']
      assert_equal 'match_record_closed', altes_spiel.reload.game_status
      assert_equal 'aftergame', neues_spiel.reload.game_status
    end

    # Der Abschluss ist eine Folge des Wechsels, keine Bedingung dafuer. Ein
    # Altbestand-Spiel, das sich querstellt, darf den Wechsel nicht
    # zurueckdrehen.
    test 'ein gescheiterter Sammelabschluss laesst den Saisonwechsel stehen' do
      login(@admin)

      PastSeasonReportCloser.stub(:call, ->(**) { raise ActiveRecord::StatementInvalid, 'kaputt' }) do
        patch '/api/v2/admin/settings/current_season', params: { season_id: 18 }
      end

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal 18, body['current_season_id']
      assert_equal 18, Setting.current_season_id
      assert body['closed_reports_error'].present?
    end

    test 'Admin aktiviert nicht-existierende Saison → 422' do
      login(@admin)
      patch '/api/v2/admin/settings/current_season', params: { season_id: 9999 }
      assert_response :unprocessable_entity
    end

    private

    def create_user(user_group_id:, game_operation_id:)
      User.create!(
        user_name: "settingsuser_#{SecureRandom.hex(4)}",
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

    def spiel_in(league, status:)
      game_day = create(:game_day, league: league, club: create(:club))
      Game.create!(
        game_day: game_day,
        home_team: create(:team, league: league),
        guest_team: create(:team, league: league),
        game_status: status,
        forfait: 0, overtime: false, legacy: false,
        events: [], players: { 'home' => [], 'guest' => [] }
      )
    end
  end
end
