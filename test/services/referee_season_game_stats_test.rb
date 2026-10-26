require 'test_helper'

class RefereeSeasonGameStatsTest < ActiveSupport::TestCase
  setup do
    @setting = create(:setting, current_season_id: '18')
    @referee = create(:referee)
  end

  test 'zaehlt laufende Saison und Vorsaison, gesamt und Grossfeld ab U15' do
    game_in(league(season_id: '18', field_size: 'GF', age_group: 'Herren'))
    game_in(league(season_id: '18', field_size: 'GF', age_group: 'U15 Junioren'))
    game_in(league(season_id: '18', field_size: 'GF', age_group: 'U13 Junioren'))
    game_in(league(season_id: '18', field_size: 'KF', age_group: 'Herren'))
    game_in(league(season_id: '17', field_size: 'GF', age_group: 'U17 Juniorinnen'))
    game_in(league(season_id: '17', field_size: 'KF', age_group: 'U11 Junioren'))

    current, previous = RefereeSeasonGameStats.for(@referee)

    assert_equal({ season_id: 18, current: true, games: 4, games_gf_u15_plus: 2 },
                 current.slice(:season_id, :current, :games, :games_gf_u15_plus))
    assert_equal({ season_id: 17, current: false, games: 2, games_gf_u15_plus: 1 },
                 previous.slice(:season_id, :current, :games, :games_gf_u15_plus))
    assert_equal 'Saison 2025/26', current[:season_name]
  end

  # Playoff- und Endrundenligen lassen Feldgroesse und Altersklasse oft leer,
  # dann gilt die Hauptrunde.
  test 'Playoff ohne eigene Felder erbt Grossfeld und Altersklasse der Hauptrunde' do
    main = league(season_id: '18', field_size: 'GF', age_group: 'U17 Junioren')
    game_in(league(season_id: '18', field_size: nil, age_group: nil, league_id_preround: main.id))
    youth = league(season_id: '18', field_size: 'GF', age_group: 'U13 Junioren')
    game_in(league(season_id: '18', field_size: nil, age_group: nil, league_id_preround: youth.id))

    current, = RefereeSeasonGameStats.for(@referee)

    assert_equal 2, current[:games]
    assert_equal 1, current[:games_gf_u15_plus]
  end

  test 'Grossfeld ohne Altersklasse zaehlt mit, Liga ohne Feldgroesse nicht' do
    game_in(league(season_id: '18', field_size: 'GF', age_group: nil))
    game_in(league(season_id: '18', field_size: nil, age_group: 'Herren'))

    current, = RefereeSeasonGameStats.for(@referee)

    assert_equal 2, current[:games]
    assert_equal 1, current[:games_gf_u15_plus]
  end

  test 'aeltere Saisons und fremde Spiele zaehlen nicht' do
    game_in(league(season_id: '16', field_size: 'GF', age_group: 'Herren'))
    create(:game, game_day: create(:game_day, league: league(season_id: '18', field_size: 'GF')),
                  officiating_referee_ids: [create(:referee).id])

    current, previous = RefereeSeasonGameStats.for(@referee)

    assert_equal [0, 0], [current[:games], previous[:games]]
  end

  # Der manuelle Saisonwechsel setzt nur current_season_id um. Die neue Saison
  # muss bei null anfangen, die bisherige zur Vorsaison werden.
  test 'nach dem Saisonwechsel wird die bisherige Saison zur Vorsaison' do
    game_in(league(season_id: '18', field_size: 'GF', age_group: 'Herren'))
    switch_season_to(19)

    current, previous = RefereeSeasonGameStats.for(@referee)

    assert_equal({ season_id: 19, games: 0, games_gf_u15_plus: 0 },
                 current.slice(:season_id, :games, :games_gf_u15_plus))
    assert_equal({ season_id: 18, games: 1, games_gf_u15_plus: 1 },
                 previous.slice(:season_id, :games, :games_gf_u15_plus))
  end

  test 'ohne fruehere Saison gibt es nur die laufende' do
    @setting.update!(seasons: { '18' => { 'name' => '2025/26' } })
    Setting.flush_current_cache

    assert_equal([18], RefereeSeasonGameStats.for(@referee).map { |s| s[:season_id] })
  end

  test 'Vorsaison ist der naechstkleinere Schluessel, nicht die Nummer davor' do
    @setting.update!(seasons: { '15' => 'Saison 2022/23', '17' => 'Saison 2024/25', '19' => 'Saison 2026/27' })
    switch_season_to(17)

    assert_equal 15, Setting.previous_season_id
  end

  private

  def league(season_id:, field_size: nil, age_group: nil, league_id_preround: nil)
    create(:league, season_id: season_id, field_size: field_size, age_group: age_group,
                    league_id_preround: league_id_preround)
  end

  def game_in(league)
    create(:game, game_day: create(:game_day, league: league), officiating_referee_ids: [@referee.id])
  end

  def switch_season_to(season_id)
    @setting.update!(systems: { '1' => { 'current_season_id' => season_id } })
    Setting.flush_current_cache
  end
end
