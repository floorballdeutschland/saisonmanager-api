require 'test_helper'
require 'csv'

module Admin
  class RefereeObservationReportsControllerTest < ActionDispatch::IntegrationTest
    setup do
      # FD ist national → RSK/Ansetzer kollabieren auf den globalen Scope 0.
      @fd = create(:game_operation, national: true)
      @lv_go = create(:game_operation)

      @coach = create(:referee, vorname: 'Clara', nachname: 'Coach')
      @referee = create(:referee)
      @fd_obs = observation_in(@fd, date: '2026-10-04', coach: @coach, rated: @referee)
      @lv_obs = observation_in(@lv_go, date: '2026-09-20')
    end

    test 'FD-RSK sieht alle Boegen, neueste Spiele zuerst' do
      login(create(:user, :rsk_scoped, game_operation_id: @fd.id))
      get '/api/v2/admin/referee_observation_report'
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal([@fd_obs.id, @lv_obs.id], body['observations'].map { |o| o['id'] })
      assert_includes body['options']['coaches'].map { |c| c['id'] }, @coach.id
      assert_includes body['options']['referees'].map { |r| r['id'] }, @referee.id
      assert_equal [@fd.id, @lv_go.id].sort, body['options']['game_operations'].map { |g| g['id'] }.sort
    end

    test 'LV-RSK sieht nur die Boegen des eigenen Spielbetriebs, auch in den Auswahllisten' do
      login(create(:user, :rsk_scoped, game_operation_id: @lv_go.id))
      get '/api/v2/admin/referee_observation_report'
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal([@lv_obs.id], body['observations'].map { |o| o['id'] })
      assert_not_includes body['options']['coaches'].map { |c| c['id'] }, @coach.id
      assert_not_includes body['options']['referees'].map { |r| r['id'] }, @referee.id
      assert_equal([@lv_go.id], body['options']['game_operations'].map { |g| g['id'] })
    end

    test 'SBK und Vereinsmanager haben keinen Zugriff' do
      login(create(:user, :sbk_global))
      get '/api/v2/admin/referee_observation_report'
      assert_response :forbidden

      login(create(:user, :vm))
      get '/api/v2/admin/referee_observation_report/export.csv'
      assert_response :forbidden
    end

    test 'zurueckgenommene Boegen nur auf ausdruecklichen Statusfilter' do
      @lv_obs.update!(status: 'hidden')
      login(create(:user, :admin))

      get '/api/v2/admin/referee_observation_report'
      assert_equal [@fd_obs.id], ids_of(response)

      get '/api/v2/admin/referee_observation_report', params: { status: 'hidden' }
      assert_equal [@lv_obs.id], ids_of(response)

      get '/api/v2/admin/referee_observation_report', params: { status: 'all' }
      assert_equal [@fd_obs.id, @lv_obs.id], ids_of(response)
    end

    test 'filtert nach Coach, Schiedsrichter, Spielbetrieb, Zeitraum und Saison' do
      login(create(:user, :admin))

      get '/api/v2/admin/referee_observation_report', params: { coach_id: @coach.id }
      assert_equal [@fd_obs.id], ids_of(response)

      get '/api/v2/admin/referee_observation_report', params: { referee_id: @referee.id }
      assert_equal [@fd_obs.id], ids_of(response)

      get '/api/v2/admin/referee_observation_report', params: { game_operation_id: @lv_go.id }
      assert_equal [@lv_obs.id], ids_of(response)

      get '/api/v2/admin/referee_observation_report', params: { from: '2026-10-01', to: '2026-10-31' }
      assert_equal [@fd_obs.id], ids_of(response)

      @lv_obs.game.game_day.league.update!(season_id: '17')
      get '/api/v2/admin/referee_observation_report', params: { season_id: '17' }
      assert_equal [@lv_obs.id], ids_of(response)
    end

    test 'CSV-Export enthaelt Kopfdaten und Noten, aber keine Freitexte' do
      login(create(:user, :admin))
      get '/api/v2/admin/referee_observation_report/export.csv'
      assert_response :success
      assert_equal 'text/csv', response.media_type

      rows = CSV.parse(response.body, headers: true)
      assert_equal 2, rows.size
      row = rows.find { |r| r['Coach'] == @fd_obs.coach_name }
      assert_equal '2026-10-04', row['Datum']
      assert_equal @fd.name, row['Spielbetrieb']
      assert_equal '5', row['Schiedsrichter 1 Stocklinie']
      assert_equal '6', row['Schiedsrichter 1 Spielleitung']
      assert_nil row['Schiedsrichter 2']
      assert_equal '4', row['Gespann Strafenlinie']

      RefereeObservation::TEXT_ATTRIBUTES.each do |field|
        assert_not_includes response.body, @fd_obs[field], "Freitext #{field} gehoert nicht in den Export"
      end
    end

    test 'Export nur der ausgewaehlten Boegen' do
      login(create(:user, :admin))
      get '/api/v2/admin/referee_observation_report/export.csv', params: { ids: [@lv_obs.id] }
      assert_response :success
      assert_equal 1, CSV.parse(response.body, headers: true).size
    end

    # Die Auswahl schickt der Browser. Sie darf den Scope nicht aufweiten: Eine
    # fremde ID faellt still heraus, statt den Bogen zu liefern.
    test 'Auswahl mit fremder ID liefert keinen Bogen ausserhalb des eigenen Spielbetriebs' do
      login(create(:user, :rsk_scoped, game_operation_id: @lv_go.id))
      get '/api/v2/admin/referee_observation_report/export.csv', params: { ids: [@fd_obs.id] }
      assert_response :success
      assert_equal 0, CSV.parse(response.body, headers: true).size
    end

    test 'Excel-Export' do
      login(create(:user, :admin))
      get '/api/v2/admin/referee_observation_report/export.xlsx'
      assert_response :success
      assert_equal Admin::RefereeObservationReportsController::XLSX_MIME, response.media_type
      assert response.body.start_with?('PK'), 'xlsx ist ein Zip-Archiv'
    end

    private

    def observation_in(game_operation, date:, coach: create(:referee), rated: nil)
      league = create(:league, game_operation: game_operation)
      game = create(:game, game_day: create(:game_day, league: league, date: date))
      create(:referee_observation, :with_rating, game: game, coach: coach, coach_name: "#{coach.vorname} #{coach.nachname}",
                                                 rated_referee: rated)
    end

    def ids_of(response)
      assert_response :success
      JSON.parse(response.body)['observations'].map { |o| o['id'] }
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
