require 'test_helper'

# Betreuer im öffentlichen Spielbericht (full_hash). Freigegeben ab Saison
# 2026/2027 (season_id 18), Unterschriften bleiben draußen.
class GamePublicCoachesTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @club = create(:club)
    @arena = create(:arena)
  end

  def game_for(season_id, coaches: {}, guest_coaches: {})
    league = create(:league, game_operation: @go, season_id: season_id)
    game_day = GameDay.create!(league: league, arena: @arena, club: @club, number: 1, date: '2026-09-05')
    Game.create!(
      game_day: game_day,
      home_team: create(:team, league: league, club: @club),
      guest_team: create(:team, league: league, club: @club),
      started: true, ended: false, forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] },
      home_team_coaches: coaches, guest_team_coaches: guest_coaches
    )
  end

  test 'alle belegten Betreuerplaetze stehen im oeffentlichen Spielbericht' do
    game = game_for('18', coaches: {
                      'coach1_string' => 'Meier, Anna', 'coach1_first_name' => 'Anna', 'coach1_last_name' => 'Meier',
                      'coach2_string' => 'Sanchez, Bruno', 'coach2_first_name' => 'Bruno', 'coach2_last_name' => 'Sanchez',
                      'coach5_string' => 'Wolf, Carla', 'coach5_first_name' => 'Carla', 'coach5_last_name' => 'Wolf'
                    })

    coaches = game.full_hash[:home_coaches]

    assert_equal [1, 2, 5], coaches.pluck(:slot)
    assert_equal ['Meier, Anna', 'Sanchez, Bruno', 'Wolf, Carla'], coaches.pluck(:name)
    assert_equal 'Anna', coaches.first[:first_name]
    assert_equal 'Meier', coaches.first[:last_name]
  end

  test 'die Unterschrift bleibt draussen' do
    game = game_for('18', coaches: {
                      'coach1_string' => 'Meier, Anna', 'coach1_first_name' => 'Anna',
                      'coach1_last_name' => 'Meier', 'coach1_signed' => true
                    })

    assert_equal [%i[slot first_name last_name name]], game.full_hash[:home_coaches].map(&:keys).uniq
    assert_includes game.hidden_elements[:home_team_coaches], 'coach1_signed'
  end

  test 'beide Mannschaften werden getrennt ausgegeben' do
    game = game_for(
      '18',
      coaches: { 'coach1_first_name' => 'Anna', 'coach1_last_name' => 'Meier' },
      guest_coaches: { 'coach1_first_name' => 'Bruno', 'coach1_last_name' => 'Sanchez' }
    )

    assert_equal ['Meier, Anna'], game.full_hash[:home_coaches].pluck(:name)
    assert_equal ['Sanchez, Bruno'], game.full_hash[:guest_coaches].pluck(:name)
  end

  test 'Altdaten ohne getrennte Namensteile kommen ueber den Sammelstring' do
    game = game_for('18', coaches: { 'coach1_string' => 'Meier, Anna' })

    coach = game.full_hash[:home_coaches].first

    assert_equal 'Meier, Anna', coach[:name]
    assert_equal '', coach[:first_name]
  end

  test 'halbleere Eintraege verlieren das ueberzaehlige Komma' do
    game = game_for('18', coaches: {
                      'coach1_string' => 'Meier, ', 'coach2_string' => ', Anna', 'coach3_string' => ', '
                    })

    assert_equal %w[Meier Anna], game.full_hash[:home_coaches].pluck(:name)
  end

  test 'leere und unangetastete Spalten liefern eine leere Liste' do
    assert_empty game_for('18').full_hash[:home_coaches]
    # Historischer Spaltendefault ist [] (Array), nicht {}.
    assert_empty game_for('18', coaches: []).full_hash[:home_coaches]
  end

  test 'vergangene Saisons zeigen keine Betreuer' do
    game = game_for('17', coaches: { 'coach1_first_name' => 'Anna', 'coach1_last_name' => 'Meier' })

    assert_empty game.full_hash[:home_coaches]
    # Intern bleiben sie sichtbar, nur öffentlich nicht.
    assert_equal 'Meier', game.hidden_elements[:home_team_coaches]['coach1_last_name']
  end

  test 'kuenftige Saisons zeigen Betreuer weiterhin' do
    game = game_for('19', coaches: { 'coach1_first_name' => 'Anna', 'coach1_last_name' => 'Meier' })

    assert_equal ['Meier, Anna'], game.full_hash[:home_coaches].pluck(:name)
  end
end
