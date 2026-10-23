require 'test_helper'

# Der genaue Anker aus dem Tabletmodus (api#816) für Sprungmarken (api#815).
class StreamTimelineTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @game = create(:game, game_status: 'match_record_closed', players: { 'home' => [], 'guest' => [] },
                          events: [{ 'id' => 1, 'event_type' => 'goal', 'event_team' => 'home', 'period' => 1,
                                     'time' => '05:00', 'home_goals' => 1, 'guest_goals' => 0,
                                     'home_number' => 2000, 'added_at' => (@start + 30.minutes).to_i }])
    @broadcast = StreamBroadcast.create!(broadcast_id: 'bc', game: @game, actual_start_at: @start,
                                         vod_duration_seconds: 7200)
  end

  test 'ohne Schuss: Eingabezeit mit 120 s Vorlauf' do
    timeline = StreamTimeline.new(@game, @broadcast)
    goal = timeline.goals.first

    assert_not goal.shot?
    assert_equal 1800 - 120, timeline.chapter_position(goal)
  end

  test 'verknüpfter Tor-Schuss geht vor, mit 10 s Vorlauf' do
    GameShot.create!(game: @game, client_uuid: 's1', team: 'home', period: 1, tapped_at: @start + 28.minutes,
                     x: 0.8, y: 0.5, result: 'goal', event_id: 1)
    timeline = StreamTimeline.new(@game, @broadcast)
    goal = timeline.goals.first

    assert goal.shot?
    assert_equal 1680 - 10, timeline.chapter_position(goal)
  end

  test 'Freischläge setzen nie den Anker, auch nicht mit fälschlicher Verknüpfung (fe#589)' do
    GameShot.create!(game: @game, client_uuid: 'f1', kind: 'free_hit', team: 'home', period: 1,
                     tapped_at: @start + 27.minutes, x: 0.6, y: 0.5)
    verbogen = GameShot.create!(game: @game, client_uuid: 'f2', team: 'home', period: 1,
                                tapped_at: @start + 28.minutes, x: 0.8, y: 0.5, result: 'goal', event_id: 1)
    verbogen.update_columns(kind: 'free_hit')

    timeline = StreamTimeline.new(@game, @broadcast)
    goal = timeline.goals.first

    assert_not goal.shot?
    assert_equal 1800 - 120, timeline.chapter_position(goal)
  end

  test 'Positionen außerhalb der Aufzeichnung sind nil' do
    timeline = StreamTimeline.new(@game, @broadcast)

    assert_nil timeline.position(@start - 1.minute, 0)
    assert_nil timeline.position(@start + 3.hours, 0)
  end

  # --- Kalibrierung (fe#560) ---------------------------------------------------

  test 'Versatz verschiebt Sprungmarke und Szene nach hinten, das Bild liegt hinter der Halle' do
    GameShot.create!(game: @game, client_uuid: 's1', team: 'home', period: 1, tapped_at: @start + 28.minutes,
                     x: 0.8, y: 0.5, result: 'goal', event_id: 1)
    @broadcast.update!(offset_seconds: 22)
    timeline = StreamTimeline.new(@game, @broadcast)
    goal = timeline.goals.first

    assert_equal 1680, timeline.anchor_second(goal.anchor_at), 'Grundlage der Kalibrierung ohne Versatz'
    assert_equal 1680 + 22 - 10, timeline.chapter_position(goal)
    assert_equal [1680 + 22 - 12, 1680 + 22 + 8], timeline.scene(goal.anchor_at), 'kalibriert: 20-s-Fenster'
  end

  test 'Versatz wirkt auch auf Sprungmarken mit Eingabezeit als Anker' do
    @broadcast.update!(offset_seconds: 15)
    timeline = StreamTimeline.new(@game, @broadcast)

    assert_equal 1800 + 15 - 120, timeline.chapter_position(timeline.goals.first)
  end

  test 'ohne Kalibrierung das bisherige Fenster, Versatz 0 ist eine Kalibrierung' do
    timeline = StreamTimeline.new(@game, @broadcast)
    assert_equal [1680 - 15, 1680 + 5], timeline.scene(@start + 28.minutes)

    @broadcast.update!(offset_seconds: 0)
    timeline = StreamTimeline.new(@game, @broadcast)
    assert_equal [1680 - 12, 1680 + 8], timeline.scene(@start + 28.minutes)
  end

  test 'negativer Versatz zieht die Szene nach vorn' do
    @broadcast.update!(offset_seconds: -5)
    timeline = StreamTimeline.new(@game, @broadcast)

    assert_equal [1680 - 5 - 12, 1680 - 5 + 8], timeline.scene(@start + 28.minutes)
  end

  test 'Versatz außerhalb der Spanne wird abgewiesen' do
    assert_not @broadcast.update(offset_seconds: 121)
    assert_not @broadcast.update(offset_seconds: 1.5)
  end

  test 'vorgemerkte Szenen sind Marken, keine Tore' do
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 1, tapped_at: @start + 20.minutes)
    timeline = StreamTimeline.new(@game, @broadcast)

    assert_equal(['m1'], timeline.marks.map { |mark| mark.shot.client_uuid })
    assert_equal 1, timeline.goals.size
  end
end
