require 'test_helper'
require 'rake'

# Tests für lib/tasks/backfill_legacy_home_clubs.rake. Der Task ordnet
# vereinslosen Profilen aus dem Altdaten-Import einen OFFENEN Heimatverein zu,
# damit die Vereine sie im eigenen Konto sehen und mergen können. Getestet werden
# Scope-SQL, Schreibpfad, DRY_RUN, Gruppen-Filter, Idempotenz, Abbruchbedingung
# und die Rücknahme.
class BackfillLegacyHomeClubsTest < ActiveSupport::TestCase
  SOURCE = LegacyImport::HomeClubBackfill::SOURCE

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @backfill = Rake::Task['players:backfill_legacy_home_clubs']
    @rollback = Rake::Task['players:rollback_legacy_home_clubs']

    @club = create(:club, name: 'ATS Buntentor')
    @other_club = create(:club, name: 'ETV Hamburg')
    @team = create(:team, club: @club)
  end

  def run_task(task, env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }.first
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def legacy_player(first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17', team: @team)
    create(:player, first_name:, last_name:, birthdate:, clubs: [],
                    with_licenses: [{ id: 'LIC:fvn:2013_2014:1541', team:,
                                      status: License::APPROVED, created_at: '2013-09-10T16:36:37' }])
  end

  def own_entries(player)
    player.reload.clubs.select { |c| c['source'] == SOURCE }
  end

  test 'DRY_RUN ist der Standard und schreibt nichts' do
    player = legacy_player

    output = run_task(@backfill)

    assert_match(/DRY RUN/, output)
    assert_match(/ATS Buntentor/, output)
    assert_empty player.reload.clubs
  end

  test 'setzt einen offenen Heimateintrag mit Belegzeitpunkt und Marker' do
    player = legacy_player

    run_task(@backfill, 'DRY_RUN' => 'false')

    entries = own_entries(player)
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal @club.id, entry['club_id']
    assert entry['home_club']
    assert_nil entry['valid_until'], 'ohne offenes Ende fehlt das Profil in Club#players'
    assert_equal '2013-09-10T16:36:37', entry['created_at']
    assert_equal SOURCE, entry['source']
  end

  test 'das Profil steht danach in der Vereins-Spielerliste' do
    player = legacy_player
    assert_not_includes @club.players.map(&:id), player.id

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_includes @club.reload.players.map(&:id), player.id
  end

  test 'PLAYER_IDS begrenzt den Lauf auf einzelne Profile' do
    treffer = legacy_player
    anderer = legacy_player(first_name: 'Marie', birthdate: '1995-10-09')

    run_task(@backfill, 'DRY_RUN' => 'false', 'PLAYER_IDS' => treffer.id.to_s)

    assert_equal 1, own_entries(treffer).size
    assert_empty anderer.reload.clubs
  end

  test 'GROUPS schliesst nicht genannte Gruppen vom Schreiben aus' do
    player = legacy_player # Gruppe E

    run_task(@backfill, 'DRY_RUN' => 'false', 'GROUPS' => 'A,D')

    assert_empty player.reload.clubs
  end

  test 'zweiter Lauf ist idempotent' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    first = own_entries(player)

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal first, own_entries(player)
    assert_match(/unverändert/, output)
  end

  test 'korrigiert den eigenen Eintrag, wenn sich die Entscheidung aendert' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    assert_equal @club.id, own_entries(player).first['club_id']

    # Jetzt taucht eine aktive Dublette in einem anderen Verein auf: die schlägt
    # den Lizenz-Verein, weil der Merge dort stattfinden muss.
    create(:player, first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                    clubs: [{ 'club_id' => @other_club.id, 'home_club' => true,
                              'created_at' => '2015-08-01T00:00:00+02:00' }])

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal @other_club.id, own_entries(player).first['club_id']
    assert_equal 1, own_entries(player).size
  end

  test 'fremde clubs-Eintraege nehmen das Profil aus dem Scope' do
    player = legacy_player
    player.update!(clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }])

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_empty own_entries(player)
    assert_equal 1, player.reload.clubs.size
  end

  test 'Abbruch, wenn der Zielverein zum Platzhalter geworden ist' do
    legacy_player
    @club.update!(name: 'Ablage Doppelung')

    # Der Verein steht dann in der Ignore-Liste, die Entscheidung liefert keinen
    # Verein mehr — geschrieben wird nichts, ein Abbruch ist nicht nötig.
    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_match(/G:/, output)
    assert_empty Player.where.not(clubs: []).where("clubs::text LIKE '%#{SOURCE}%'")
  end

  test 'Rollback entfernt nur die eigenen Eintraege' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    assert_equal 1, own_entries(player).size

    run_task(@rollback, 'DRY_RUN' => 'false')

    assert_empty own_entries(player)
    assert_empty player.reload.clubs
  end

  test 'der Merge verwirft den Eintrag, wenn der Master denselben Verein aktiv hat' do
    # Der Regelfall: genau dafür wird der Verein gesetzt, also deckt der offene
    # Heimateintrag des Masters ihn ab (_merge_clubs verwirft die Dopplung).
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                             clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'created_at' => '2015-08-01T00:00:00+02:00' }])
    run_task(@backfill, 'DRY_RUN' => 'false')

    player.reload.merge_into!(master, create(:user).id)

    assert_empty own_entries(master), 'der Backfill hinterlaesst nach dem Merge keine Spur'
    assert_equal 1, master.reload.clubs.size
  end

  test 'Rollback greift auch beim Master, wenn der Merge den Eintrag weitergegeben hat' do
    # Sonderfall: der Master hat den Verein nur GESCHLOSSEN, also ergaenzt
    # _merge_clubs den offenen Backfill-Eintrag statt ihn zu verwerfen.
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Oelgemöller', birthdate: '1997-09-17',
                             clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'created_at' => '2013-08-01T00:00:00+02:00',
                                       'valid_until' => '2015-07-31T00:00:00+02:00' }])
    run_task(@backfill, 'DRY_RUN' => 'false')
    player.reload.merge_into!(master, create(:user).id)
    assert_equal 1, own_entries(master).size, 'merge_into! haengt den Eintrag an den Master'

    run_task(@rollback, 'DRY_RUN' => 'false')

    assert_empty own_entries(master)
    assert_equal 1, master.reload.clubs.size, 'der echte Heimateintrag bleibt'
  end

  test 'Rollback im DRY_RUN aendert nichts' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')

    output = run_task(@rollback)

    assert_match(/DRY RUN/, output)
    assert_equal 1, own_entries(player).size
  end
end
