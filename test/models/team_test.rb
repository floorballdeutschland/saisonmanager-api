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
end
