require 'test_helper'

# Setting ist Singleton (`Setting.first`); die Factory ersetzt vorhandene
# Setting-Zeilen pro Test. Tests hier decken die Symptome aus PR #168 ab —
# `current_min_team`-Fallback auf 0, wenn `min_team_id` in der Saison fehlt.
class SettingTest < ActiveSupport::TestCase
  test 'current_season_id liest aus systems["1"]["current_season_id"]' do
    create(:setting, current_season_id: 18)

    assert_equal 18, Setting.current_season_id
  end

  test 'current_season_id reagiert auf andere Saison-Werte' do
    create(:setting, current_season_id: 17)

    assert_equal 17, Setting.current_season_id
  end

  test 'current_min_team liefert gesetzten Wert' do
    create(:setting, current_season_id: '18', current_min_team: 1500)

    assert_equal 1500, Setting.current_min_team
  end

  test 'current_min_team ohne min_team_id-Eintrag → 0 (Bonner-Bug aus PR #168)' do
    # Ohne explizites min_team_id für die aktuelle Saison fällt
    # Setting.current_min_team auf 0 zurück. Das ist exakt der Pfad, der die
    # Vorsaison-Lizenzen weiterhin als „aktuell" durchließ.
    create(:setting, current_season_id: '18', current_min_team: nil)

    assert_equal 0, Setting.current_min_team
  end

  test 'current_min_league ohne Wert → 0 (analoges Verhalten)' do
    create(:setting, current_season_id: '18', current_min_league: nil)

    assert_equal 0, Setting.current_min_league
  end

  test 'current_min_league liefert gesetzten Wert' do
    create(:setting, current_season_id: '18', current_min_league: 4200)

    assert_equal 4200, Setting.current_min_league
  end

  test 'league_class liefert den Namen zum Code' do
    create(:setting, league_classes: { 'rl' => { 'name' => 'Regionalliga' } })

    assert_equal 'Regionalliga', Setting.league_class('rl')
  end

  test 'league_class liefert für unbekannte Keys und fehlende Map leeren String (kein Crash, #297)' do
    create(:setting, league_classes: { 'rl' => { 'name' => 'Regionalliga' } })
    assert_equal '', Setting.league_class('30')
    assert_equal '', Setting.league_class(nil)

    Setting.first.update_columns(league_classes: nil)
    assert_equal '', Setting.league_class('rl')
  end

  test 'seasons liefert sortierte Liste mit current-Markierung' do
    create(:setting, current_season_id: '18')

    seasons = Setting.seasons
    assert_kind_of Array, seasons
    refute_empty seasons
    current_entries = seasons.select { |s| s[:current] }
    assert_equal 1, current_entries.size
    assert_equal 18, current_entries.first[:id]
  end
end
