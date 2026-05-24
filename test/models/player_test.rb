require 'test_helper'

# Tests für Lizenz-Filter-Verhalten von Player. Decken die Pfade ab, die zum
# „Bonner-Anträge"-Vorfall (Mai 2026) geführt haben: 27 Februar-Anträge eines
# Vereins hingen weiter als „beantragt" in der Lizenzansicht, weil
# `Setting.current_min_team` über fehlende `min_team_id`-Werte auf 0 fiel und
# Vorsaison-Lizenzen dadurch durch den Filter rutschten.
class PlayerTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Player#full_hash(with_licenses=true, only_current_licenses=true)
  # ---------------------------------------------------------------------------

  test 'full_hash mit only_current_licenses=true liefert nur Lizenzen oberhalb current_min_team' do
    previous_league = create(:league, :previous_season)
    current_league  = create(:league, :current_season)
    previous_team   = create(:team, league: previous_league)
    current_team    = create(:team, league: current_league)

    # Schwelle so legen, dass nur das spätere current_team durchgelassen wird.
    # Team-IDs in einem frischen Test sind aufsteigend; das früher angelegte
    # previous_team hat die kleinere ID.
    create(:setting, current_season_id: '18', current_min_team: current_team.id)

    player = create(:player, with_licenses: [
      { team: previous_team, status: License::APPROVED },
      { team: current_team,  status: License::APPROVED }
    ])

    result = player.full_hash(true, true)
    license_team_ids = result[:licenses].map { |l| l['team_id'] }
    assert_includes license_team_ids, current_team.id
    refute_includes license_team_ids, previous_team.id
  end

  test 'full_hash mit current_min_team=0 (Fallback aus PR #168) lässt alle Lizenzen durch' do
    # Genau dieser Pfad ist der Bonner-Vorfall: ohne min_team_id rutschen
    # Lizenzen aus jeder Saison durch den Filter.
    create(:setting, current_season_id: '18', current_min_team: nil)

    previous_league = create(:league, :previous_season)
    previous_team   = create(:team, league: previous_league)
    current_league  = create(:league, :current_season)
    current_team    = create(:team, league: current_league)

    player = create(:player, with_licenses: [
      { team: previous_team, status: License::APPROVED },
      { team: current_team,  status: License::APPROVED }
    ])

    assert_equal 0, Setting.current_min_team, 'Vorbedingung: min_team fällt auf 0'

    result = player.full_hash(true, true)
    assert_equal 2, result[:licenses].size,
                 'Mit min_team=0 sind ALLE Lizenzen current — exakt der Bug'
  end

  test 'full_hash mit only_current_licenses=false ignoriert current_min_team' do
    create(:setting, current_season_id: '18', current_min_team: 1500)
    league = create(:league, :previous_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    result = player.full_hash(true, false)
    assert_equal 1, result[:licenses].size
  end

  test 'full_hash ohne with_licenses liefert keine licenses-Sektion' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)
    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED }
    ])

    result = player.full_hash
    refute result.key?(:licenses)
  end

  # ---------------------------------------------------------------------------
  # Player#current_licenses(season_id)
  # ---------------------------------------------------------------------------

  test 'current_licenses liefert nur Lizenzen, deren Team zur Saison gehört' do
    create(:setting, current_season_id: '18')

    current_league = create(:league, :current_season)
    other_league   = create(:league, :previous_season)
    current_team   = create(:team, league: current_league)
    other_team     = create(:team, league: other_league)

    player = create(:player, with_licenses: [
      { team: current_team, status: License::APPROVED },
      { team: other_team,   status: License::APPROVED }
    ])

    result = player.current_licenses('18')

    assert_equal 1, result.size
    assert_equal current_team.id, result.first['team_id']
  end

  test 'current_licenses verwendet teams_by_season, nicht season_id auf der Lizenz' do
    # Selbst wenn season_id auf der Lizenz falsch wäre, zählt die Team-Saison.
    # Sichert die Erwartung aus Issue #173 Punkt 2.
    create(:setting, current_season_id: '18')

    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED, season_id: '17' }
    ])

    assert_equal 1, player.current_licenses('18').size
  end

  test 'current_licenses ohne Lizenzen liefert nil oder leeres Array' do
    create(:setting, current_season_id: '18')
    player = create(:player)

    result = player.current_licenses('18')
    assert(result.nil? || result.empty?)
  end
end
