require 'test_helper'

class TeamTest < ActiveSupport::TestCase
  test 'current_season enthält nur Teams der aktuellen Saison, nicht Alt-Saisons' do
    create(:setting, current_season_id: '18')
    current = create(:team, league: create(:league, :current_season))
    # Alt-Saison mit (im Test) potenziell höherer league_id – früher per
    # ID-Schwelle fälschlich „aktuell", jetzt über season_id korrekt ausgeschlossen.
    archived = create(:team, league: create(:league, :archived_season))

    ids = Team.current_season.pluck(:id)
    assert_includes ids, current.id
    refute_includes ids, archived.id
  end

  # ---------------------------------------------------------------------------
  # ticker_hash – teams.short_name ist nullable und ohne Validierung
  # ---------------------------------------------------------------------------

  test 'ticker_hash nutzt das hinterlegte Kuerzel' do
    team = create(:team, name: 'Floorball Musterstadt', short_name: 'FBMS')

    assert_equal 'FBMS', team.ticker_hash[:shortName]
  end

  test 'ticker_hash kuerzt ein mehrteiliges Kuerzel am ersten Wort' do
    team = create(:team, short_name: 'FBM Zweite')

    assert_equal 'FBM', team.ticker_hash[:shortName]
  end

  test 'ticker_hash faellt ohne Kuerzel auf den Namen zurueck' do
    # Ohne Rueckfall starb slice mit NoMethodError und riss die ganze
    # Ticker-Antwort der Liga mit.
    team = create(:team, name: 'Musterstadt', short_name: nil)

    assert_equal 'Muste', team.ticker_hash[:shortName]
  end

  test 'ticker_hash faellt auch bei leerem Kuerzel auf den Namen zurueck' do
    team = create(:team, name: 'Musterstadt', short_name: '')

    assert_equal 'Muste', team.ticker_hash[:shortName]
  end
end
