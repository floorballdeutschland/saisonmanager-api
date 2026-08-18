require 'test_helper'
require 'rake'

# Tests fuer players:reopen_memberships_after_deactivation
# (lib/tasks/reopen_memberships_after_deactivation.rake): oeffnet die
# Vereinszugehoerigkeiten, die eine Deaktivierung vor api#472 geschlossen hat, und
# laesst Kennzeichnung wie Lizenzen unangetastet.
class ReopenMembershipsAfterDeactivationTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:reopen_memberships_after_deactivation']
    @task.reenable

    create(:setting, current_season_id: '18')
    @user   = create(:user)
    @club   = create(:club)
    @league = create(:league, :current_season)
  end

  def run_task(env = { 'DRY_RUN' => 'false' })
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def alt_deaktiviert(reason: 'Vereinsaustritt')
    player = create(:player,
                    clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                    with_licenses: [{ team: create(:team, league: @league), status: License::APPROVED }])
    legacy_deactivate!(player, @user.id, reason: reason)
    player.reload
  end

  test 'oeffnet die geschlossene Zugehoerigkeit' do
    player = alt_deaktiviert
    assert_not_nil player.clubs.first['valid_until'], 'Vorbedingung: Alt-Zustand steht'

    run_task
    player.reload

    assert_nil player.clubs.first['valid_until']
    assert_includes @club.players(include_deactivated: true).map(&:id), player.id
  end

  test 'laesst die Kennzeichnung des Vereins stehen' do
    player = alt_deaktiviert

    run_task
    player.reload

    assert_not_nil player.deactivated_at
    assert_equal @user.id, player.deactivated_by
    assert_equal 'Vereinsaustritt', player.deactivation_reason
    refute_includes @club.players.map(&:id), player.id, 'aus der aktiven Liste bleibt es heraus'
  end

  # Was eine alte Deaktivierung ungueltig gesetzt hat, bleibt ungueltig. Der Lauf
  # macht niemanden wieder spielberechtigt.
  test 'laesst die Lizenzen ungueltig' do
    player = alt_deaktiviert
    verlauf_vorher = player.licenses.first['history'].size

    run_task
    player.reload

    assert_equal verlauf_vorher, player.licenses.first['history'].size
    assert_equal License::DELETED, player.licenses.first['history'].last['license_status_id'].to_i
  end

  test 'DRY_RUN schreibt nichts' do
    player = alt_deaktiviert
    vorher = player.clubs.to_json

    run_task({})
    player.reload

    assert_equal vorher, player.clubs.to_json
  end

  # Bei einer zusammengefuehrten Dublette ist die geschlossene Zugehoerigkeit richtig:
  # ihre Eintraege liegen am Master. Wuerde der Lauf sie oeffnen, stuende die Dublette
  # wieder als Mitglied in der Vereinsliste.
  test 'ueberspringt zusammengefuehrte Dubletten' do
    master   = create(:player)
    dublette = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    dublette.merge_into!(master, @user.id)
    dublette.reload
    geschlossen_am = dublette.clubs.first['valid_until']

    run_task
    dublette.reload

    assert_equal geschlossen_am, dublette.clubs.first['valid_until']
  end

  test 'REASONS beschraenkt den Lauf auf die genannten Gruende' do
    austritt = alt_deaktiviert(reason: 'Vereinsaustritt')
    karriere = alt_deaktiviert(reason: 'Karriereende')

    run_task({ 'DRY_RUN' => 'false', 'REASONS' => 'Vereinsaustritt' })

    assert_nil austritt.reload.clubs.first['valid_until']
    assert_not_nil karriere.reload.clubs.first['valid_until'],
                   'ein nicht genannter Grund bleibt unberuehrt'
  end

  test 'aktive Profile bleiben unberuehrt' do
    aktiv = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])

    run_task
    aktiv.reload

    assert_nil aktiv.deactivated_at
    assert_nil aktiv.clubs.first['valid_until']
  end
end
