require 'test_helper'

# Virtuelle Highlights aus Tablet-Spielen (fe#555), API-Teil.
class GameHighlightsTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @game = create(:game, ended: true, tablet_capture_at: @start,
                          players: {
                            'home' => [{ 'trikot_number' => 7, 'player_firstname' => 'Max', 'player_name' => 'Müller' },
                                       { 'trikot_number' => 9, 'player_firstname' => 'Tom', 'player_name' => 'Schmidt' }],
                            'guest' => []
                          },
                          events: [goal(1, 'home', 7, 9, 1, 0, @start + 40.minutes),
                                   goal(2, 'home', 9, nil, 2, 0, @start + 50.minutes),
                                   goal(3, 'guest', 2000, nil, 2, 1, @start + 60.minutes)])
    @broadcast = StreamBroadcast.create!(broadcast_id: 'vid-1', game: @game, actual_start_at: @start,
                                         vod_duration_seconds: 7200)
    @game.update_columns(live_stream_link: 'https://www.youtube.com/watch?v=vid-1')
    shot('s1', 'home', @start + 38.minutes, 1)
    shot('s3', 'guest', @start + 58.minutes, 3)
  end

  test 'Szenen nur für Tore mit verknüpftem Schuss, 15 s davor bis 5 s danach' do
    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = response.parsed_body
    assert_equal 'vid-1', body['video_id']
    assert_equal([1, 3], body['scenes'].map { |s| s['event_id'] })
    erste = body['scenes'].first
    assert_equal 2280 - 15, erste['start']
    assert_equal 2280 + 5, erste['end']
    assert_equal({ 'trikot_number' => 7, 'name' => 'Max Müller' }, erste['scorer'])
    assert_equal({ 'trikot_number' => 9, 'name' => 'Tom Schmidt' }, erste['assist'])
    assert_equal [1, 0, 1, 'home'], erste.values_at('home_goals', 'guest_goals', 'period', 'team')
    assert_nil body['scenes'].last['scorer'], 'nicht angegebener Schütze'
  end

  test 'ohne Tabletmodus 404, ohne Schlüssel 401' do
    @game.update_columns(tablet_capture_at: nil)
    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
    assert_response :not_found

    get "/api/v2/games/#{@game.id}/highlights.json"
    assert_response :unauthorized
  end

  test 'ohne Übertragung mit bekanntem Start: video_id null, keine Szenen' do
    @broadcast.update!(actual_start_at: nil)

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal({ 'video_id' => nil, 'scenes' => [] }, response.parsed_body)
  end

  test 'Szenen außerhalb der Aufzeichnung fallen weg, das Ende wird abgeschnitten' do
    @broadcast.update!(vod_duration_seconds: 2283)

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    scenes = response.parsed_body['scenes']
    assert_equal([1], scenes.map { |s| s['event_id'] })
    assert_equal 2283, scenes.first['end']
  end

  test 'Name einer anonymisierten Person ohne Nachnamen' do
    spieler = create(:player, public_last_name_hidden_at: Time.current)
    @game.players['home'][0]['player_id'] = spieler.id
    @game.save!
    PublicPlayerNames.flush!

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal 'Max', response.parsed_body['scenes'].first['scorer']['name']
    assert_not_includes response.body, 'Müller'
  end

  test 'nicht verlinkte (nicht gelistete) Aufzeichnung: video_id null' do
    @game.update_columns(live_stream_link: nil, vod_link: nil)

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal({ 'video_id' => nil, 'scenes' => [] }, response.parsed_body)
    assert_not_includes response.body, 'vid-1'
  end

  test 'ohne bekannte Länge der Aufzeichnung gibt es Szenen, nur ohne Abschneiden' do
    @broadcast.update!(vod_duration_seconds: nil)

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal([1, 3], response.parsed_body['scenes'].map { |s| s['event_id'] })
    assert_equal 3480 + 5, response.parsed_body['scenes'].last['end']
  end

  test 'ein Schuss weniger als 15 s nach Streamstart fällt weg' do
    GameShot.find_by(client_uuid: 's1').update_columns(tapped_at: @start + 10.seconds)

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal([3], response.parsed_body['scenes'].map { |s| s['event_id'] })
  end

  test 'bei mehreren Übertragungen gilt die mit den meisten Szenen' do
    StreamBroadcast.create!(broadcast_id: 'vid-2', game: @game, actual_start_at: @start + 55.minutes,
                            vod_duration_seconds: 3600)
    @game.update_columns(vod_link: 'https://youtu.be/vid-2')

    get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }

    assert_equal 'vid-1', response.parsed_body['video_id']
  end

  test 'eine neue Verknüpfung leert den Zwischenspeicher' do
    with_real_cache do
      get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
      assert_equal 2, response.parsed_body['scenes'].size

      neu = shot('s2', 'home', @start + 49.minutes, nil)
      GameShotLinker.link_new_goal(@game, { event_team: 'home', id: 2, period: 1, time: '12:00' })
      assert_equal 2, neu.reload.event_id

      get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
      assert_equal 3, response.parsed_body['scenes'].size
    end
  end

  private

  def goal(id, team, number, assist, home, guest, added_at)
    event = { 'id' => id, 'event_type' => 'goal', 'event_team' => team, 'period' => 1,
              'time' => "#{id + 10}:00", 'home_goals' => home, 'guest_goals' => guest,
              "#{team}_number" => number, 'added_at' => added_at.to_i }
    event["#{team}_assist"] = assist if assist
    event
  end

  def shot(uuid, team, tapped_at, event_id)
    GameShot.create!(game: @game, client_uuid: uuid, team: team, period: 1, tapped_at: tapped_at,
                     x: 0.8, y: 0.5, result: 'goal', event_id: event_id)
  end
end
