require 'test_helper'
require Rails.root.join('db/migrate/20260613100000_normalize_league_class_ids')

# Daten-Migration zu Issue #297: Legacy-league_class_id-Werte werden auf die
# fünf Formular-Codes (1fbl/2fbl/rl/vl/ll) bzw. '' normalisiert.
class NormalizeLeagueClassIdsTest < ActiveSupport::TestCase
  def run_migration
    ActiveRecord::Migration.suppress_messages { NormalizeLeagueClassIds.new.up }
  end

  # --- normalize (reine Mapping-Logik) ---------------------------------------

  test 'normalize: Codes und leere Werte bleiben unverändert' do
    assert_equal 'rl', NormalizeLeagueClassIds.normalize('rl', 'Regionalliga Ost')
    assert_equal '', NormalizeLeagueClassIds.normalize('', 'Regionalliga Ost')
    assert_equal '', NormalizeLeagueClassIds.normalize(nil, 'Verbandsliga')
  end

  test 'normalize: eindeutige Namensmuster gewinnen vor dem Wert-Mapping' do
    assert_equal '1fbl', NormalizeLeagueClassIds.normalize('40', '1. FBL Herren - Playdowns')
    assert_equal '2fbl', NormalizeLeagueClassIds.normalize('20', '2. Floorball Bundesliga')
    assert_equal 'rl', NormalizeLeagueClassIds.normalize('280', 'Regionalliga Südwest U15 (KF)')
    assert_equal 'vl', NormalizeLeagueClassIds.normalize('370', 'Verbandsliga Nordwest Herren (KF)')
    assert_equal 'll', NormalizeLeagueClassIds.normalize('50', 'Landesliga Nordwest Herren (KF)')
  end

  test 'normalize: DM-Muster schlägt das Wert-Mapping der gemischt belegten Werte' do
    assert_equal '', NormalizeLeagueClassIds.normalize('280', 'U15 Junioren Kleinfeld Deutsche Meisterschaft')
    assert_equal '', NormalizeLeagueClassIds.normalize('300', 'U13 Juniorinnen Kleinfeld Deutsche Meisterschaft')
    # Süd-/Nord-/...deutsche Meisterschaften sind überregionale Runden, keine
    # nationale Endrunde — sie bleiben beim Wert-Mapping.
    assert_equal 'rl', NormalizeLeagueClassIds.normalize('30', 'Süddeutsche Meisterschaft Herren GF')
  end

  test 'normalize: Wert-Mapping als Fallback ohne Namenstreffer' do
    assert_equal '1fbl', NormalizeLeagueClassIds.normalize('10', 'Playdowns')
    assert_equal '2fbl', NormalizeLeagueClassIds.normalize('20', 'Playoffs')
    assert_equal 'rl', NormalizeLeagueClassIds.normalize('30', 'Süddeutsche Meisterschaft')
    assert_equal 'vl', NormalizeLeagueClassIds.normalize('330', 'Meisterrunde U11')
    assert_equal 'll', NormalizeLeagueClassIds.normalize('50', 'Herren KF')
  end

  test 'normalize: DM/Pokal/Trophy-Werte ohne Klassenrang werden leer' do
    %w[0 25 200 260 500 505 520].each do |value|
      assert_equal '', NormalizeLeagueClassIds.normalize(value, 'Deutsche Meisterschaft Herren'),
                   "#{value} sollte '' ergeben"
    end
  end

  # --- up (Datenbestand) ------------------------------------------------------

  # Legacy-Werte kommen an der neuen Inclusion-Validierung vorbei in die DB
  # (wie der echte Altbestand, der vor der Validierung geschrieben wurde).
  def create_legacy_league(league_class_id, attrs)
    create(:league, attrs).tap { |l| l.update_columns(league_class_id:) }
  end

  test 'up: normalisiert Ligen aller Saisons' do
    create(:setting)
    legacy_rl = create_legacy_league('30', name: 'Regionalligameisterschaft', season_id: '17')
    legacy_dm = create_legacy_league('520', name: 'Deutsche Meisterschaft Herren', season_id: '16')
    legacy_buli = create_legacy_league('1', name: '1. Floorball-Bundesliga Herren', season_id: '18')
    code_league = create(:league, league_class_id: 'vl', name: 'Verbandsliga Bayern', season_id: '18')

    run_migration

    assert_equal 'rl', legacy_rl.reload.league_class_id
    assert_equal '', legacy_dm.reload.league_class_id
    assert_equal '1fbl', legacy_buli.reload.league_class_id
    assert_equal 'vl', code_league.reload.league_class_id
  end

  test 'up: Lizenz-Kopien folgen der Liga ihres Teams, Waisen dem Wert-Mapping' do
    create(:setting)
    league = create_legacy_league('30', name: 'Irgendeine Liga', season_id: '17')
    team = create(:team, league:)
    player = create(:player, with_licenses: [
      { team:, league_class_id: '30' },
      { team:, id: 'orphan', league_class_id: '20' }
    ])
    # Waisen-Lizenz: Team existiert nicht (mehr)
    orphan = player.licenses.find { |l| l['id'] == 'orphan' }
    orphan['team_id'] = -1
    player.save!

    run_migration

    player.reload
    team_license = player.licenses.find { |l| l['id'] != 'orphan' }
    orphan_license = player.licenses.find { |l| l['id'] == 'orphan' }
    assert_equal 'rl', team_license['league_class_id']
    assert_equal '2fbl', orphan_license['league_class_id']
  end

  test 'up: Lizenz folgt auch einer Liga, die auf leer normalisiert wird' do
    create(:setting)
    dm_league = create_legacy_league('520', name: 'Deutsche Meisterschaft Herren', season_id: '16')
    team = create(:team, league: dm_league)
    player = create(:player, with_licenses: [{ team:, league_class_id: '520' }])

    run_migration

    assert_equal '', dm_league.reload.league_class_id
    assert_equal '', player.reload.licenses.first['league_class_id']
  end

  test 'up: Player ohne Lizenzen (nil) bleibt unangetastet' do
    create(:setting)
    player = create(:player)
    player.update_columns(licenses: nil)

    run_migration

    assert_nil player.reload.licenses
  end

  test 'up: schlüsselt die league_classes-Settings-Map auf die Codes um' do
    create(:setting)

    run_migration

    classes = Setting.current['league_classes']
    assert_equal %w[1fbl 2fbl ll rl vl], classes.keys.sort
    assert_equal 'Regionalliga', classes['rl']['name']
  end
end
