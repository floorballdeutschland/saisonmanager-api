require 'test_helper'
require 'rake'

# Tests für lib/tasks/backfill_club_home_game_operations.rake bzw.
# ClubHomeGameOperationResolver: die beiden Ableitungswege (Mannschaften,
# Landesverband), der Landesverband aus der Postleitzahl und die Fälle, in denen
# der Task bewusst nichts entscheidet.
class BackfillClubHomeGameOperationsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['clubs:backfill_home_game_operations']
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

  # Ein Verein, auf den ein Eintrag aus CLUB_OVERRIDES passt: id UND Namensmerkmal.
  # Beides ist nötig, siehe Kommentar an der Tabelle im Task.
  def club_matching_override(club_id, override, **attrs)
    create(:club, id: club_id, name: "SV #{override[:name_includes]}", **attrs)
  end

  # Erster Eintrag der Tabelle als Paar [id, Eintrag].
  def first_override
    ClubHomeGameOperationResolver::CLUB_OVERRIDES.first
  end

  # Ein Landesverband mit zugehörigem Spielbetrieb.
  def association_with_operation(short_name)
    sa = create(:state_association, short_name: short_name)
    [sa, create(:game_operation, state_association_id: sa.id)]
  end

  def team_in(club, game_operation)
    create(:team, club: club, league: create(:league, game_operation: game_operation))
  end

  def home_go_id(club)
    club.reload.game_operations_hash.find { |e| e['home_game_operation'] }&.fetch('game_operation_id')
  end

  # --- Ableitung aus den Mannschaften ---------------------------------------

  test 'setzt den Spielbetrieb, in dem der Verein die meisten Mannschaften hatte' do
    _sa_a, go_a = association_with_operation('NWFV')
    _sa_b, go_b = association_with_operation('FVH')
    club = create(:club, game_operations_hash: [])
    2.times { team_in(club, go_a) }
    team_in(club, go_b)

    run_task('DRY_RUN' => 'false')

    assert_equal go_a.id, home_go_id(club)
  end

  test 'nationale Spielbetriebe zaehlen bei der Ableitung nicht mit' do
    _sa, go = association_with_operation('NWFV')
    national = create(:game_operation, :national, state_association_id: create(:state_association).id)
    club = create(:club, game_operations_hash: [])
    team_in(club, go)
    3.times { team_in(club, national) }

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club), 'ein Zweitligist bestimmt keinen Heimatverband'
  end

  test 'entscheidet bei Gleichstand nicht, sondern listet auf' do
    _sa_a, go_a = association_with_operation('NWFV')
    _sa_b, go_b = association_with_operation('FVH')
    club = create(:club, game_operations_hash: [])
    team_in(club, go_a)
    team_in(club, go_b)

    out, = run_task('DRY_RUN' => 'false')

    assert_nil home_go_id(club)
    assert_match(/no_majority/, out)
  end

  # Muster Frankfurt Falcons: 3 Mannschaften in Baden-Württemberg, je 2 in Hessen
  # und NRW. Nach schlichter Mehrzahl käme Baden-Württemberg heraus, obwohl der
  # Verein dort nicht einmal die Hälfte seiner Mannschaften hatte.
  test 'entscheidet bei knapper Mehrzahl ohne Mehrheit nicht' do
    _sa_a, go_a = association_with_operation('FVBW')
    _sa_b, go_b = association_with_operation('FVH')
    _sa_c, go_c = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [])
    3.times { team_in(club, go_a) }
    2.times { team_in(club, go_b) }
    2.times { team_in(club, go_c) }

    out, = run_task('DRY_RUN' => 'false')

    assert_nil home_go_id(club)
    assert_match(/no_majority/, out)
  end

  test 'zaehlt Mannschaften, nicht Ligen' do
    _sa_a, go_a = association_with_operation('NWFV')
    _sa_b, go_b = association_with_operation('FVH')
    club = create(:club, game_operations_hash: [])
    # Zwei Mannschaften in EINER Liga bei A, eine Mannschaft bei B: nach Ligen
    # wäre das 1:1 und damit unentschieden, nach Mannschaften 2:1 für A.
    league_a = create(:league, game_operation: go_a)
    2.times { create(:team, club: club, league: league_a) }
    team_in(club, go_b)

    run_task('DRY_RUN' => 'false')

    assert_equal go_a.id, home_go_id(club)
  end

  test 'beruecksichtigt Mannschaften aus Spielgemeinschaften' do
    _sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [])
    create(:team, league: create(:league, game_operation: go), syndicate_clubs: [club.id])

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
  end

  # --- Landesverband beim Ableiten aus Mannschaften -------------------------

  test 'setzt den Landesverband aus der Postleitzahl, nicht aus dem Spielbetrieb' do
    sa_sh, go_sh = association_with_operation('FLV-SH')
    sa_hh = create(:state_association, short_name: 'FBH')
    # Hamburger Verein, der im SH-Spielbetrieb spielt (Muster SV Eidelstedt).
    club = create(:club, game_operations_hash: [], postcode: '22523', state_association_id: nil)
    team_in(club, go_sh)

    run_task('DRY_RUN' => 'false')

    assert_equal go_sh.id, home_go_id(club), 'Spielbetrieb aus den Ligen'
    assert_equal sa_hh.id, club.reload.state_association_id, 'Landesverband aus der PLZ'
    refute_equal sa_sh.id, club.state_association_id
  end

  test 'faellt ohne Postleitzahl auf den Landesverband des Spielbetriebs zurueck' do
    sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [], postcode: nil, state_association_id: nil)
    team_in(club, go)

    run_task('DRY_RUN' => 'false')

    assert_equal sa.id, club.reload.state_association_id
  end

  test 'ueberschreibt einen vorhandenen Landesverband nicht' do
    _sa, go = association_with_operation('NWFV')
    other = create(:state_association, short_name: 'FVH')
    club = create(:club, game_operations_hash: [], postcode: '48143', state_association_id: other.id)
    team_in(club, go)

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
    assert_equal other.id, club.reload.state_association_id
  end

  # --- Ableitung aus dem Landesverband --------------------------------------

  test 'leitet ohne Mannschaften aus dem Landesverband ab' do
    sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [], state_association_id: sa.id)

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
  end

  test 'nutzt bei untergeordnetem Landesverband den Spielbetrieb des Dachverbands' do
    parent, parent_go = association_with_operation('SBKOST')
    child = create(:state_association, short_name: 'FVSA', parent_id: parent.id)
    club = create(:club, game_operations_hash: [], state_association_id: child.id)

    run_task('DRY_RUN' => 'false')

    assert_equal parent_go.id, home_go_id(club)
  end

  test 'ordnet Hamburg dem SH-Spielbetrieb zu (kein eigener Spielbetrieb)' do
    _sa_sh, go_sh = association_with_operation('FLV-SH')
    sa_hh = create(:state_association, short_name: 'FBH')
    club = create(:club, game_operations_hash: [], state_association_id: sa_hh.id)

    run_task('DRY_RUN' => 'false')

    assert_equal go_sh.id, home_go_id(club)
    assert_equal sa_hh.id, club.reload.state_association_id, 'der Landesverband bleibt Hamburg'
  end

  test 'ordnet einen Verein am Bundesverband dem nationalen Spielbetrieb zu' do
    sa_fd = create(:state_association, short_name: 'FVD')
    go_fd = create(:game_operation, :national, state_association_id: sa_fd.id)
    club = create(:club, game_operations_hash: [], state_association_id: sa_fd.id)

    run_task('DRY_RUN' => 'false')

    assert_equal go_fd.id, home_go_id(club)
  end

  # --- Ausdrückliche Zuordnung (CLUB_OVERRIDES) -----------------------------

  test 'ordnet einen Verein aus CLUB_OVERRIDES dem benannten Verband zu' do
    club_id, override = first_override
    sa, go = association_with_operation(override[:sa_short])
    wrong = create(:state_association, short_name: 'FVBW-falsch')
    club = club_matching_override(club_id, override, game_operations_hash: [],
                                                    state_association_id: wrong.id)

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
    assert_equal sa.id, club.reload.state_association_id,
                 'die Zuordnung korrigiert den falschen Landesverband, sie bestätigt ihn nicht'
  end

  test 'CLUB_OVERRIDES schlaegt die Ableitung aus den Mannschaften' do
    club_id, override = first_override
    _sa, go = association_with_operation(override[:sa_short])
    _other_sa, other_go = association_with_operation('NWFV')
    club = club_matching_override(club_id, override, game_operations_hash: [])
    5.times { team_in(club, other_go) }

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
  end

  # Das Merkmal zählt auch, wenn es im long_name statt im name steht.
  test 'erkennt das Namensmerkmal auch im langen Vereinsnamen' do
    club_id, override = first_override
    _sa, go = association_with_operation(override[:sa_short])
    club = create(:club, id: club_id, name: 'FGH',
                         long_name: "Fit und Gesund #{override[:name_includes]} e.V.",
                         game_operations_hash: [])

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
  end

  test 'listet einen Verein auf, dessen Override-Kuerzel es nicht gibt' do
    club_id, override = first_override
    club = club_matching_override(club_id, override, game_operations_hash: [])

    out, = run_task('DRY_RUN' => 'false')

    assert_nil home_go_id(club)
    assert_match(/unknown_sa_short/, out)
  end

  # Die Zuordnung darf nicht allein an der id hängen: Die gilt nur in dem Bestand,
  # für den sie notiert wurde. Am 12.08.2026 hat das die CI vorgeführt – unter Seed
  # 26598 bekam der Verein des Gleichstand-Tests die id 284 und wurde zu „Landau in
  # der Pfalz".
  test 'ein Override greift nicht bei fremdem Verein mit derselben id' do
    club_id, override = first_override
    _sa_override, go_override = association_with_operation(override[:sa_short])
    _sa_teams, go_teams = association_with_operation('NWFV')
    club = create(:club, id: club_id, name: 'Irgendein anderer Verein', game_operations_hash: [])
    team_in(club, go_teams)

    run_task('DRY_RUN' => 'false')

    assert_equal go_teams.id, home_go_id(club), 'normale Ableitung statt Zuordnung nach id'
    refute_equal go_override.id, home_go_id(club)
  end

  # Und nicht allein am Namen: Ortsnamen sind nicht eindeutig. „Landau" liegt außer
  # in der Pfalz auch an der Isar und bei Bad Arolsen. Ein Verein von dort trägt
  # einen RICHTIGEN Landesverband, den die Zuordnung überschreiben würde.
  test 'ein Override greift nicht bei gleichem Namen und anderer id' do
    club_id, override = first_override
    _sa_override, go_override = association_with_operation(override[:sa_short])
    sa_by, go_by = association_with_operation('FVBY')
    # id ausdrücklich setzen und zwar eine, die in der Tabelle NICHT steht: Käme sie
    # aus der Sequenz, könnte sie zufällig club_id treffen – dann greift der Eintrag
    # doch und der Test prüfte das Gegenteil von dem, was er behauptet.
    club = create(:club, id: club_id + 100_000, name: "TSV #{override[:name_includes]} an der Isar",
                         game_operations_hash: [], state_association_id: sa_by.id)
    3.times { team_in(club, go_by) }

    run_task('DRY_RUN' => 'false')

    assert_equal go_by.id, home_go_id(club), 'die Mannschaften entscheiden'
    refute_equal go_override.id, home_go_id(club)
    assert_equal sa_by.id, club.reload.state_association_id,
                 'der richtige Landesverband darf nicht überschrieben werden'
  end

  # Ein leeres Merkmal darf auf nichts passen. Ohne die Prüfung trifft include?('')
  # jeden Namen, und ein versehentlich leerer Eintrag zieht JEDEN Verein ohne
  # Heimat-Spielbetrieb in seinen Verband.
  test 'ein Eintrag ohne Namensmerkmal greift nirgends' do
    resolver = ClubHomeGameOperationResolver.new
    club = create(:club, name: 'Irgendein Verein')

    refute resolver.override_fits?(club, { name_includes: '' })
    refute resolver.override_fits?(club, { sa_short: 'RLPSAAR' })
  end

  # Ein Eintrag, der nicht greift, muss auffallen: Nach einer Umbenennung bestätigt
  # die normale Ableitung sonst wieder unbemerkt den falschen Landesverband.
  test 'meldet eine Zuordnung, deren Verein das Merkmal nicht traegt' do
    club_id, override = first_override
    create(:club, id: club_id, name: 'Nach Umbenennung ohne Merkmal', game_operations_hash: [])

    out, = run_task('DRY_RUN' => 'false')

    assert_match(/Ausdrückliche Zuordnungen, die nicht greifen/, out)
    assert_match(/##{club_id} → #{override[:sa_short]}/, out)
    assert_match(/heißt "Nach Umbenennung ohne Merkmal"/, out)
  end

  test 'meldet eine Zuordnung, zu deren id es keinen Verein gibt' do
    club_id, = first_override

    out, = run_task('DRY_RUN' => 'false')

    assert_match(/Ausdrückliche Zuordnungen, die nicht greifen/, out)
    assert_match(/##{club_id} .*kein Verein mit dieser id/, out)
  end

  test 'meldet nichts, wenn alle Zuordnungen greifen' do
    ClubHomeGameOperationResolver::CLUB_OVERRIDES.each do |club_id, override|
      association_with_operation(override[:sa_short]) unless
        StateAssociation.exists?(short_name: override[:sa_short])
      club_matching_override(club_id, override, game_operations_hash: [])
    end

    out, = run_task('DRY_RUN' => 'false')

    refute_match(/Ausdrückliche Zuordnungen, die nicht greifen/, out)
  end

  # --- Nichts zu entscheiden ------------------------------------------------

  test 'ueberspringt Vereine ohne Mannschaften und ohne Landesverband' do
    club = create(:club, game_operations_hash: [], state_association_id: nil)

    out, = run_task('DRY_RUN' => 'false')

    assert_nil home_go_id(club)
    assert_match(/no_source/, out)
  end

  test 'laesst Vereine mit Heimat-Spielbetrieb unberuehrt' do
    _sa, go = association_with_operation('NWFV')
    _sa_b, other_go = association_with_operation('FVH')
    club = create(:club, game_operations_hash: [{ 'home_game_operation' => true,
                                                 'game_operation_id' => go.id }])
    3.times { team_in(club, other_go) }

    run_task('DRY_RUN' => 'false')

    assert_equal go.id, home_go_id(club)
  end

  # --- Bestand und Schreibform ---------------------------------------------

  test 'behaelt Gast-Eintraege und schreibt die Kennung als Zahl' do
    _sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [{ 'game_operation_id' => 4711,
                                                 'home_game_operation' => false }])
    team_in(club, go)

    run_task('DRY_RUN' => 'false')

    hash = club.reload.game_operations_hash
    assert_includes hash, { 'game_operation_id' => 4711, 'home_game_operation' => false }
    home = hash.find { |e| e['home_game_operation'] }
    assert_equal go.id, home['game_operation_id']
    assert_kind_of Integer, home['game_operation_id'],
                   'als String findet den Verein keine der jsonb-Abfragen'
  end

  test 'Dry-Run schreibt nichts' do
    _sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [])
    team_in(club, go)

    out, = run_task

    assert_nil home_go_id(club)
    assert_match(/DRY RUN/, out)
  end

  test 'bricht bei ungueltigem DRY_RUN-Wert ab' do
    assert_raises(SystemExit) { run_task('DRY_RUN' => 'False') }
  end

  # --- Report ---------------------------------------------------------------

  test 'der Report schreibt nichts' do
    _sa, go = association_with_operation('NWFV')
    club = create(:club, game_operations_hash: [])
    team_in(club, go)

    report = Rake::Task['clubs:home_game_operation_report']
    report.reenable
    out, = capture_io { report.invoke }

    assert_nil home_go_id(club)
    assert_match(/ohne Heimat-Spielbetrieb/, out)
    assert_match(/from_teams/, out)
  end
end
