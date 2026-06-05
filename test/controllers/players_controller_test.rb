require 'test_helper'

class PlayersControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }])
  end

  # Hilfsmethode: Login per POST /api/v2/login und Cookie speichern
  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # 1. VM kann Lizenz für eigenes Team beantragen → 201
  test 'VM beantragt Lizenz für eigenes Team erfolgreich' do
    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    # age_eligible? gibt true zurück wenn kein deadline gesetzt
    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']

    @player.reload
    assert_equal 1, @player.licenses.length
    assert_equal @team.id, @player.licenses.first['team_id']
    assert_equal License::REQUESTED, @player.licenses.first['history'].last['license_status_id']
  end

  # 2. Duplikat: bereits APPROVED Lizenz für gleiche Saison+Team → 422
  test 'Doppelter Lizenzantrag für selbes Team und Saison ergibt 422' do
    existing_license = {
      'id' => Digest::UUID.uuid_v4,
      'team_id' => @team.id,
      'season_id' => @league.season_id,
      'league_class_id' => @league.league_class_id,
      'history' => [
        {
          'license_status_id' => License::APPROVED,
          'created_at' => 1.day.ago.iso8601,
          'created_by' => nil
        }
      ]
    }
    @player.update!(licenses: [existing_license])

    admin_user = create(:user, :admin)
    login_as(admin_user)

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id },
         as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/Lizenzantrag/, body['message'])
  end

  # 3. Admin kann Lizenz genehmigen (handle_license_request mit APPROVED) → 200
  test 'Admin genehmigt Lizenzantrag erfolgreich' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    admin = create(:user, :admin)
    login_as(admin)

    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']

    @player.reload
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::APPROVED, last_status
  end

  # 4. Nicht-Admin kann nicht genehmigen → 403
  test 'Nicht-Admin kann keinen Lizenzantrag genehmigen' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED },
         as: :json

    assert_response :forbidden
  end

  # 5. Rücknahme innerhalb 24h → Lizenz komplett gelöscht
  test 'Lizenzantrag innerhalb 24h zurückgezogen – Lizenz wird gelöscht' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 1.hour.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']
    assert body['grace_period_deletion']

    @player.reload
    assert_empty @player.licenses
  end

  # 6. Rücknahme nach 24h → Status WITHDRAWN, Lizenz bleibt
  test 'Lizenzantrag nach 24h zurückgezogen – Status wird WITHDRAWN' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 2.days.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok

    @player.reload
    assert_equal 1, @player.licenses.length
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::WITHDRAWN, last_status
  end

  # 7. Rücknahme einer bereits genehmigten Lizenz → 422
  test 'Rücknahme einer genehmigten Lizenz ergibt 422' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::APPROVED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    admin = create(:user, :admin)
    login_as(admin)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :unprocessable_entity
  end
end
