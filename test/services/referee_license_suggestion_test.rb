require 'test_helper'

# Lizenzvorschlag aus den Regeln (api#861). Die Vorbelegung entspricht den
# Regeln, nach denen FD bisher von Hand entscheidet.
class RefereeLicenseSuggestionTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    Setting.first.update!(seasons: { '17' => { 'name' => 'Saison 2024/25' }, '18' => { 'name' => 'Saison 2025/26' },
                                     '19' => { 'name' => 'Saison 2026/27' } })
    Setting.flush_current_cache
    @levels = %w[J1 J2 L3 L2 L1].each_with_index.to_h do |name, i|
      [name, RefereeLicenseLevel.create!(name: name, validity_years: 1, position: i)]
    end
    rule('j', 'J1')
    rule('j', 'J2')
    rule('g', 'L3')
    rule('f', 'L1', min_games: 4, field_size: 'GF',
                    age_groups: ['Herren', 'Damen', 'U15 Junioren', 'U17 Junioren'])
    rule('f', 'L2')
    @referee = create(:referee)
  end

  test 'F-Kurs mit vier Spielen Grossfeld ab U15 ergibt L1' do
    4.times { game_in('18', 'GF', 'Herren') }

    suggestion = suggest('f', %w[L2 L1])

    assert_equal 'L1', suggestion[:lizenzstufe]
    assert_equal [18, 4, 4], suggestion.values_at(:season_id, :games, :min_games)
  end

  test 'F-Kurs mit drei Spielen ergibt L2, Kleinfeld und U13 zaehlen nicht' do
    3.times { game_in('18', 'GF', 'U17 Junioren') }
    game_in('18', 'KF', 'Herren')
    game_in('18', 'GF', 'U13 Junioren')
    game_in('17', 'GF', 'Herren')

    assert_equal 'L2', suggest('f', %w[L2 L1])[:lizenzstufe]
  end

  test 'Liga ohne Altersklasse zaehlt mit, Playoff erbt von der Hauptrunde' do
    main = create(:league, season_id: '18', field_size: 'GF', age_group: 'U13 Junioren')
    2.times { game_in('18', 'GF', nil) }
    2.times { game_in('18', nil, nil, preround: create(:league, season_id: '18', field_size: 'GF', age_group: 'Damen')) }
    game_in('18', nil, nil, preround: main)

    assert_equal 'L1', suggest('f', %w[L2 L1])[:lizenzstufe]
  end

  # Kursende Juni und September 2026 zaehlen 2025/26, Januar 2027 die
  # laufende 2026/27 (Entscheidung 26.10.2026).
  test 'massgebliche Saison haengt am Kursende' do
    4.times { game_in('18', 'GF', 'Herren') }

    assert_equal 'L1', suggest('f', %w[L2 L1], kursstichtag: Date.new(2026, 6, 20))[:lizenzstufe]
    assert_equal 'L1', suggest('f', %w[L2 L1], kursstichtag: Date.new(2026, 9, 12))[:lizenzstufe]
    january = suggest('f', %w[L2 L1], kursstichtag: Date.new(2027, 1, 16))
    assert_equal ['L2', 19], january.values_at(:lizenzstufe, :season_id)
  end

  # Ohne eigene Reihenfolge: Bedingte Regeln vor dem Rueckfall, die hoehere
  # Mindestzahl zuerst.
  test 'hoehere Mindestzahl wird zuerst geprueft' do
    rule('f', 'L3', min_games: 10, field_size: 'GF')
    10.times { game_in('18', 'GF', 'Herren') }

    assert_equal 'L3', suggest('f', %w[L3 L2 L1])[:lizenzstufe]
    assert_equal 'L1', suggest('f', %w[L2 L1])[:lizenzstufe]
  end

  test 'J-Kurs folgt der Zielstufe des Kurses' do
    assert_equal 'J1', suggest('j', %w[J1])[:lizenzstufe]
    assert_equal 'J2', suggest('j', %w[J2])[:lizenzstufe]
    assert_equal 'L3', suggest('g', %w[L3])[:lizenzstufe]
  end

  test 'neue Person ohne Schiri-Datensatz bekommt den Rueckfall' do
    4.times { game_in('18', 'GF', 'Herren') }

    assert_equal 'L2', suggest('f', %w[L2 L1], referee: nil)[:lizenzstufe]
  end

  test 'ohne passende Regel kein Vorschlag' do
    assert_nil suggest('n', %w[L1])
  end

  test 'inaktive Stufe wird nicht vorgeschlagen' do
    @levels['L3'].update!(active: false)

    assert_nil suggest('g', %w[L3])
  end

  test 'geloeschte Stufe nimmt ihre Regeln mit' do
    assert_difference -> { RefereeLicenseSuggestionRule.count }, -1 do
      @levels['L3'].destroy!
    end
  end

  private

  def rule(course_type, level, min_games: nil, field_size: 'all', age_groups: [])
    RefereeLicenseSuggestionRule.create!(course_type: course_type, referee_license_level: @levels[level],
                                         min_games: min_games, field_size: field_size,
                                         age_groups: age_groups)
  end

  def game_in(season_id, field_size, age_group, preround: nil)
    league = create(:league, season_id: season_id, field_size: field_size, age_group: age_group,
                             league_id_preround: preround&.id)
    create(:game, game_day: create(:game_day, league: league), officiating_referee_ids: [@referee.id])
  end

  def suggest(course_type, level_names, kursstichtag: Date.new(2026, 9, 12), referee: @referee)
    course = RefereeCourse.create!(title: 'Kurs', course_type: course_type, status: 'held',
                                   license_level_ids: level_names.map { |n| @levels[n].id },
                                   state_association: create(:state_association))
    result = RefereeCourseResult.create!(referee_course: course, referee: referee, status: 'pending_review',
                                         match_type: referee ? 'exact_match' : 'new_entry',
                                         match_field_count: referee ? 6 : 0, kursstichtag: kursstichtag)
    RefereeLicenseSuggestion.for(result)
  end
end
