require 'test_helper'

# Mehrere Vorrunden-Ligen über die Admin-Endpunkte (LeaguePrerounds).
class LeaguePreroundsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @staffel_a = create(:league, game_operation: @go, name: 'Staffel A')
    @staffel_b = create(:league, game_operation: @go, name: 'Staffel B')
    @folge = create(:league, game_operation: @go, name: 'Meisterrunde')
    login(create(:user, :admin))
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def save_league(attrs)
    post '/api/v2/admin/leagues',
         params: { id: @folge.id, league: { game_operation_id: @go.id, name: @folge.name }.merge(attrs) },
         as: :json
  end

  test 'speichert mehrere Vorrunden und die Übernahmestufe' do
    save_league(league_ids_preround: [@staffel_a.id, @staffel_b.id], preround_point_modus: 'full',
                preround_transfer_scope: 'goals')

    assert_response :success
    @folge.reload
    assert_equal [@staffel_a.id, @staffel_b.id], @folge.league_ids_preround
    assert_equal @staffel_a.id, @folge.league_id_preround
    assert_equal 'goals', @folge.preround_transfer_scope
  end

  test 'leere Liste entfernt alle Vorrunden' do
    @folge.update!(league_ids_preround: [@staffel_a.id, @staffel_b.id])

    save_league(league_ids_preround: [])

    assert_response :success
    assert_empty @folge.reload.league_ids_preround
    assert_nil @folge.league_id_preround
  end

  test 'älterer Client mit nur league_id_preround setzt genau diese Vorrunde' do
    @folge.update!(league_ids_preround: [@staffel_a.id, @staffel_b.id])

    save_league(league_id_preround: @staffel_b.id)

    assert_response :success
    assert_equal [@staffel_b.id], @folge.reload.league_ids_preround
  end

  test 'Ring wird mit 422 und Meldung abgewiesen' do
    @staffel_a.update!(league_ids_preround: [@folge.id])

    save_league(league_ids_preround: [@staffel_a.id])

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['message'].present?
  end

  test 'Liga-JSON nennt Vorrunden und Stufe' do
    @folge.update!(league_ids_preround: [@staffel_a.id, @staffel_b.id], preround_transfer_scope: 'full')

    get "/api/v2/leagues/#{@folge.id}.json"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [@staffel_a.id, @staffel_b.id], body['league_ids_preround']
    assert_equal 'full', body['preround_transfer_scope']
  end

  test 'copy_preround_licenses kopiert aus beiden Staffeln' do
    club_a = create(:club)
    club_b = create(:club)
    team_a = create(:team, league: @staffel_a, club: club_a, name: 'A')
    team_b = create(:team, league: @staffel_b, club: club_b, name: 'B')
    create(:team, league: @folge, club: club_a, name: 'A')
    create(:team, league: @folge, club: club_b, name: 'B')
    create(:player, with_licenses: [{ team: team_a, status: License::APPROVED }])
    create(:player, with_licenses: [{ team: team_b, status: License::APPROVED }])
    @folge.update!(league_ids_preround: [@staffel_a.id, @staffel_b.id])

    post "/api/v2/admin/leagues/#{@folge.id}/copy_preround_licenses"

    assert_response :success
    assert_equal 2, JSON.parse(response.body)['copied']
  end

  test 'zweite Vorrunde blockiert die Löschung ebenso' do
    @folge.update!(league_ids_preround: [@staffel_a.id, @staffel_b.id])

    delete "/api/v2/admin/leagues/#{@staffel_b.id}"

    assert_response :unprocessable_entity
    assert_match(/Vorrunde/, JSON.parse(response.body)['message'])
  end
end
