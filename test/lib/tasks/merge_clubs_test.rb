require 'test_helper'
require 'rake'

# Tests für lib/tasks/merge_clubs.rake bzw. ClubMergeHelper: Umhängen der
# Vereins-Referenzen (Spalten, Integer-Array, JSONB), Auflösen doppelter
# Mitgliedschaften und der Dry-Run.
class MergeClubsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['clubs:merge']
    @task.reenable
    create(:setting, current_season_id: '18')
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # --- Parsing ---------------------------------------------------------------

  test 'parse_merges liest mehrere Paare' do
    assert_equal [[286, 12], [304, 57]], ClubMergeHelper.parse_merges('286:12, 304:57')
  end

  test 'parse_merges bricht bei unlesbarem Paar ab statt es zu überspringen' do
    assert_raises(ArgumentError) { ClubMergeHelper.parse_merges('286:12,kaputt') }
  end

  test 'parse_merges liefert leer ohne Angabe' do
    assert_empty ClubMergeHelper.parse_merges('')
  end

  # --- Live-Merge ------------------------------------------------------------

  test 'hängt Mannschaften um und löscht den aufgelösten Verein' do
    source = create(:club, name: 'Frankfurt Falcons')
    target = create(:club, name: 'TSV Berkersheim')
    team = create(:team, club: source)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal target.id, team.reload.club_id
    assert_nil Club.find_by(id: source.id)
    assert Club.exists?(target.id)
  end

  test 'protokolliert den Merge' do
    source = create(:club, name: 'SSC Hochdahl')
    target = create(:club, name: 'TSV Hochdahl')

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    log = MergeLog.find_by(object_type: 'club', merged_id: source.id)
    assert_equal target.id, log.master_id
    assert_equal 'SSC Hochdahl', log.merged_label
    assert_equal 'TSV Hochdahl', log.master_label
  end

  test 'Stammdaten des verbleibenden Vereins bleiben unangetastet' do
    sa = create(:state_association)
    source = create(:club, name: 'Alt', short_name: 'ALT', state_association_id: nil)
    target = create(:club, name: 'Neu', short_name: 'NEU', state_association_id: sa.id)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    target.reload
    assert_equal 'Neu', target.name
    assert_equal 'NEU', target.short_name
    assert_equal sa.id, target.state_association_id
  end

  test 'Dry-Run verschiebt nichts' do
    source = create(:club)
    target = create(:club)
    team = create(:team, club: source)

    run_task('MERGES' => "#{source.id}:#{target.id}")

    assert_equal source.id, team.reload.club_id
    assert Club.exists?(source.id)
    assert_nil MergeLog.find_by(object_type: 'club', merged_id: source.id)
  end

  # --- Integer-Array ---------------------------------------------------------

  test 'ersetzt den Verein in teams.syndicate_clubs ohne Dublette' do
    source = create(:club)
    target = create(:club)
    other = create(:club)
    both = create(:team, syndicate_clubs: [source.id, target.id, other.id])
    only_source = create(:team, syndicate_clubs: [source.id])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal [target.id, other.id], both.reload.syndicate_clubs
    assert_equal [target.id], only_source.reload.syndicate_clubs
  end

  # --- JSONB -----------------------------------------------------------------

  test 'schreibt players.clubs um, auch bei String-club_id' do
    source = create(:club)
    target = create(:club)
    player = create(:player, clubs: [{ 'club_id' => source.id.to_s, 'team_id' => 7 }])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal([target.id], player.reload.clubs.map { |c| c['club_id'] })
  end

  test 'legt Mitgliedschaften in beiden Vereinen zu einer zusammen' do
    source = create(:club)
    target = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => source.id, 'team_id' => 7, 'valid_until' => nil },
      { 'club_id' => target.id, 'team_id' => 7, 'valid_until' => '2015-05-31' }
    ])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    entries = player.reload.clubs
    assert_equal 1, entries.size, 'ein Eintrag pro Verein und Mannschaft'
    assert_nil entries.first['valid_until'], 'die offene Mitgliedschaft überlebt'
  end

  test 'Mitgliedschaften in verschiedenen Mannschaften bleiben getrennt' do
    source = create(:club)
    target = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => source.id, 'team_id' => 7 },
      { 'club_id' => target.id, 'team_id' => 8 }
    ])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal [7, 8], player.reload.clubs.map { |c| c['team_id'] }.sort
  end

  test 'Mitgliedschaften fremder Vereine bleiben unberührt' do
    source = create(:club)
    target = create(:club)
    other = create(:club)
    player = create(:player, clubs: [
      { 'club_id' => source.id, 'team_id' => 7 },
      { 'club_id' => other.id, 'team_id' => 9 }
    ])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal [target.id, other.id].sort, player.reload.clubs.map { |c| c['club_id'] }.sort
  end

  test 'schreibt users.permissions um, auch bei String-club_id' do
    source = create(:club)
    target = create(:club)
    user = create(:user, permissions: [{ 'user_group_id' => 4, 'game_operation_id' => 1, 'club_id' => source.id.to_s }])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal([target.id], user.reload.permissions.map { |p| p['club_id'] })
  end

  test 'entdoppelt users.permissions nach dem Umschreiben' do
    source = create(:club)
    target = create(:club)
    perm = { 'user_group_id' => 4, 'game_operation_id' => 1 }
    user = create(:user, permissions: [perm.merge('club_id' => source.id), perm.merge('club_id' => target.id)])

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal 1, user.reload.permissions.size
  end

  # --- Zustaendigkeit --------------------------------------------------------

  # Der Merge fasst den Landesverband des verbleibenden Vereins nicht an: Er
  # entscheidet, wer den Verein verwaltet, und der des aufgeloesten Vereins
  # verschwindet mit ihm. Sonst koennte ein Merge die Zustaendigkeit stillschweigend
  # an einen anderen Verband uebergeben.
  test 'laesst den Landesverband des verbleibenden Vereins unveraendert' do
    ziel_sa = create(:state_association)
    ziel_go = create(:game_operation, state_association_id: ziel_sa.id)
    source = create(:club, state_association_id: create(:state_association).id)
    target = create(:club, state_association_id: ziel_sa.id)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    target.reload
    assert_equal ziel_sa.id, target.state_association_id
    assert_equal ziel_go.id, target.main_game_operation_id
  end

  # --- Unique-Index ----------------------------------------------------------

  test 'löscht überzählige Schiri-Ausschlüsse statt den Unique-Index zu brechen' do
    source = create(:club)
    target = create(:club)
    referee = create(:referee)
    RefereeClubExclusion.create!(referee_id: referee.id, club_id: source.id)
    RefereeClubExclusion.create!(referee_id: referee.id, club_id: target.id)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal 1, RefereeClubExclusion.where(referee_id: referee.id).count
    assert_equal target.id, RefereeClubExclusion.find_by(referee_id: referee.id).club_id
  end

  test 'hängt Schiri-Ausschlüsse ohne Konflikt um' do
    source = create(:club)
    target = create(:club)
    referee = create(:referee)
    exclusion = RefereeClubExclusion.create!(referee_id: referee.id, club_id: source.id)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal target.id, exclusion.reload.club_id
  end

  # Ohne referee_change_requests.new_club_id in plain_columns bricht der Merge
  # am Fremdschluessel ab, sobald ein Schiri je einen Wechsel in den
  # aufzuloesenden Verein beantragt hat.
  test 'hängt beantragte Vereinswechsel um' do
    source = create(:club)
    target = create(:club)
    referee = create(:referee, club: create(:club))
    antrag = RefereeChangeRequest.create!(referee: referee, correction_type: 'verein', new_club: source)

    run_task('MERGES' => "#{source.id}:#{target.id}", 'DRY_RUN' => 'false')

    assert_equal target.id, antrag.reload.new_club_id
    assert_not Club.exists?(source.id)
  end

  # --- Vorbedingungen --------------------------------------------------------

  test 'überspringt unbekannte IDs, ohne abzubrechen' do
    target = create(:club)
    out, = run_task('MERGES' => "999999:#{target.id}", 'DRY_RUN' => 'false')

    assert_match(/ÜBERSPRUNGEN/, out)
    assert Club.exists?(target.id)
  end

  test 'überspringt identische IDs' do
    club = create(:club)
    out, = run_task('MERGES' => "#{club.id}:#{club.id}", 'DRY_RUN' => 'false')

    assert_match(/identische ID/, out)
    assert Club.exists?(club.id)
  end
end
