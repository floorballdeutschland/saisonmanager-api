# frozen_string_literal: true

require 'test_helper'
require 'rake'

# Tests für lib/tasks/backfill_legacy_home_clubs.rake und das Helfermodul
# HomeClubBackfillTask. Abgedeckt: Bedienung (DRY_RUN, GROUPS, PLAYER_IDS,
# CSV_DIR), Schreibpfad, Fehlerbehandlung, Bericht und Rücknahme.
class BackfillLegacyHomeClubsTest < ActiveSupport::TestCase
  SOURCE = LegacyImport::HomeClubBackfill::SOURCE
  TASK_ENV_KEYS = %w[DRY_RUN GROUPS PLAYER_IDS CSV_DIR].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @backfill = Rake::Task['players:backfill_legacy_home_clubs']
    @rollback = Rake::Task['players:rollback_legacy_home_clubs']

    @club = create(:club, name: 'Verein A')
    @other_club = create(:club, name: 'Verein B')
    @team = create(:team, club: @club)
  end

  # Alle vom Task gelesenen Variablen zurücksetzen, nicht nur die gesetzten:
  # sonst wirkt ein im Shell-Umfeld exportiertes CSV_DIR in jeden Test hinein.
  # allow_exit: der Task beendet sich mit `abort`, wenn ein Profil fehlgeschlagen
  # ist. Ohne das Abfangen INNERHALB von capture_io ginge die Ausgabe verloren,
  # und genau die ist bei einem Fehllauf das Interessante.
  def run_task(task, env = {}, allow_exit: false)
    saved = ENV.to_hash.slice(*TASK_ENV_KEYS)
    TASK_ENV_KEYS.each { |k| ENV.delete(k) }
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io do
      task.invoke
    rescue SystemExit
      raise unless allow_exit
    end.first
  ensure
    TASK_ENV_KEYS.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  # ACHTUNG zwei Aufrufe mit Standardwerten erzeugen Profile mit gleichem
  # Nachnamen UND Geburtsdatum, also ein vereinsloses Paar (Gruppe I). Wer zwei
  # unabhängige Profile braucht, muss birthdate oder last_name variieren.
  def legacy_player(first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17', team: @team)
    @license_counter = (@license_counter || 0) + 1
    create(:player, first_name:, last_name:, birthdate:, clubs: [],
                    with_licenses: [{ id: "LIC:fvn:2013_2014:#{@license_counter}", team:,
                                      status: License::APPROVED, created_at: '2013-09-10T16:36:37' }])
  end

  def home_entry(club, valid_until: nil, created_at: '2015-08-01T00:00:00+02:00')
    { 'club_id' => club.id, 'home_club' => true, 'created_at' => created_at,
      'valid_until' => valid_until }.compact
  end

  def own_entries(player)
    player.reload.clubs.select { |c| c['source'] == SOURCE }
  end

  # ── Bedienung ─────────────────────────────────────────────────────────────

  test 'DRY_RUN ist der Standard und schreibt nichts' do
    player = legacy_player

    output = run_task(@backfill)

    assert_match(/DRY RUN/, output)
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

  test 'GROUPS schließt nicht genannte Gruppen vom Schreiben aus' do
    player = legacy_player # Gruppe E

    run_task(@backfill, 'DRY_RUN' => 'false', 'GROUPS' => 'A,D')

    assert_empty player.reload.clubs
  end

  test 'unlesbare PLAYER_IDS lösen KEINEN Volllauf aus' do
    player = legacy_player

    assert_raises(ArgumentError) { run_task(@backfill, 'DRY_RUN' => 'false', 'PLAYER_IDS' => '#123') }
    assert_empty player.reload.clubs, 'ein Tippfehler darf nicht den ganzen Scope schreiben'
  end

  test 'parse_player_ids akzeptiert nur reine Zahlen' do
    assert_equal [12, 34], HomeClubBackfillTask.parse_player_ids(' 12 , 34 ')
    assert_empty HomeClubBackfillTask.parse_player_ids(nil)
    assert_raises(ArgumentError) { HomeClubBackfillTask.parse_player_ids('12x') }
    assert_raises(ArgumentError) { HomeClubBackfillTask.parse_player_ids('abc') }
    assert_raises(ArgumentError) { HomeClubBackfillTask.parse_player_ids(',,') }
  end

  test 'parse_groups fällt auf die schreibenden Gruppen zurück' do
    assert_equal LegacyImport::HomeClubBackfill::WRITING_GROUPS, HomeClubBackfillTask.parse_groups(nil)
    assert_equal %w[A D], HomeClubBackfillTask.parse_groups(' A , D ')
  end

  # ── Fehlerpfade ───────────────────────────────────────────────────────────

  test 'target_club! bricht bei fehlendem Verein ab' do
    error = assert_raises(RuntimeError) do
      HomeClubBackfillTask.target_club!(legacy_player, { club_id: 999_999 }, [])
    end

    assert_match(/existiert nicht/, error.message)
  end

  test 'target_club! bricht bei einem Platzhalter-Verein ab' do
    error = assert_raises(RuntimeError) do
      HomeClubBackfillTask.target_club!(legacy_player, { club_id: @club.id }, [@club.id])
    end

    assert_match(/Platzhalter/, error.message)
  end

  test 'ein defektes Profil bricht den Lauf nicht ab, die anderen werden geschrieben' do
    kaputt = legacy_player(first_name: 'Kaputt', last_name: 'Kettental', birthdate: '1980-01-01')
    create(:player, first_name: 'Kaputt', last_name: 'Kettental', birthdate: '1980-01-01',
                    clubs: [home_entry(@other_club)])
    intakt = legacy_player(first_name: 'Intakt', last_name: 'Sauber', birthdate: '1981-02-02')

    # Der Zielverein der Dublette verschwindet: für Gruppe A kommt die club_id aus
    # dem clubs-JSONB eines anderen Profils und kann auf einen gelöschten Verein zeigen.
    @other_club.delete

    assert_raises(SystemExit) { run_task(@backfill, 'DRY_RUN' => 'false') }

    assert_equal 1, own_entries(intakt).size, 'das intakte Profil wurde geschrieben'
    assert_empty own_entries(kaputt)
  end

  test 'der Bericht erscheint auch dann, wenn ein Profil fehlschlägt' do
    legacy_player(first_name: 'Kaputt', last_name: 'Kettental', birthdate: '1980-01-01')
    create(:player, first_name: 'Kaputt', last_name: 'Kettental', birthdate: '1980-01-01',
                    clubs: [home_entry(@other_club)])
    @other_club.delete

    output = run_task(@backfill, { 'DRY_RUN' => 'false' }, allow_exit: true)

    assert_match(/=== Einordnung ===/, output)
    assert_match(/=== Fehler/, output)
    assert_match(/Ergebnis:/, output)
  end

  # ── Idempotenz ────────────────────────────────────────────────────────────

  test 'zweiter Lauf ist idempotent' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    first = own_entries(player)

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal first, own_entries(player)
    assert_match(/unverändert/, output)
  end

  test 'korrigiert den eigenen Eintrag, wenn sich die Entscheidung ändert' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    assert_equal @club.id, own_entries(player).first['club_id']

    # Jetzt taucht eine aktive Dublette in einem anderen Verein auf: die schlägt
    # den Lizenz-Verein, weil der Merge dort stattfinden muss.
    create(:player, first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                    clubs: [home_entry(@other_club)])

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal @other_club.id, own_entries(player).first['club_id']
    assert_equal 1, own_entries(player).size
  end

  test 'ein von Hand geschlossener eigener Eintrag wird nicht wieder geöffnet' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    clubs = player.reload.clubs
    clubs.first['valid_until'] = 1.day.ago.iso8601
    player.update!(clubs:)

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_not_nil own_entries(player).first['valid_until']
    assert_match(/von Hand geschlossen/, output)
  end

  test 'fremde clubs-Einträge nehmen das Profil aus dem Scope' do
    player = legacy_player
    player.update!(clubs: [home_entry(@other_club)])

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_empty own_entries(player)
    assert_equal 1, player.reload.clubs.size
  end

  # ── Gruppen D und I durchgängig ───────────────────────────────────────────

  test 'Gruppe D schreibt und erscheint in der Admin-Liste' do
    player = legacy_player(first_name: 'Mark Oli', last_name: 'Ruhend', birthdate: '1993-11-07')
    dublette = create(:player, first_name: 'Mark-Oliver', last_name: 'Ruhend', birthdate: '1993-11-07',
                               clubs: [home_entry(@other_club, valid_until: 1.week.ago.iso8601)],
                               deactivated_at: 1.week.ago)

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal @other_club.id, own_entries(player).first['club_id']
    assert_match(/\[D\]/, output)
    assert_match(/Gruppe D: Merge nur per Admin/, output)
    assert_match(/secondary_id=/, output)
    assert_match(/##{dublette.id}/, output)
  end

  test 'Gruppe I schreibt für beide Profile eines vereinslosen Paares' do
    einer = legacy_player(first_name: 'Arthur', last_name: 'Paarweise', birthdate: '2006-07-23')
    anderer = legacy_player(first_name: 'Arthur', last_name: 'Paarweise', birthdate: '2006-07-23')

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal @club.id, own_entries(einer).first['club_id']
    assert_equal @club.id, own_entries(anderer).first['club_id']
    assert_match(/\[I\]/, output)
    assert_includes @club.reload.players.map(&:id), einer.id
  end

  test 'ein vereinsloses Paar bleibt über zwei Läufe stabil in Gruppe I' do
    # Nach dem ersten Lauf tragen beide nur eigene Einträge, bleiben also im Scope
    # und sind weiter füreinander vereinslose Partner. Ohne diese Eigenschaft würde
    # der zweite Lauf die eigene Vermutung als Gruppe A zurücklesen.
    einer = legacy_player(first_name: 'Arthur', last_name: 'Paarweise', birthdate: '2006-07-23')
    legacy_player(first_name: 'Arthur', last_name: 'Paarweise', birthdate: '2006-07-23')
    run_task(@backfill, 'DRY_RUN' => 'false')

    output = run_task(@backfill, 'DRY_RUN' => 'false')

    assert_match(/\[I\]/, output)
    assert_no_match(/\[A\]/, output)
    assert_equal @club.id, own_entries(einer).first['club_id']
  end

  # ── Rücknahme ─────────────────────────────────────────────────────────────

  test 'Rollback entfernt nur die eigenen Einträge und benennt sie' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    assert_equal 1, own_entries(player).size

    output = run_task(@rollback, 'DRY_RUN' => 'false')

    assert_empty own_entries(player)
    assert_empty player.reload.clubs
    assert_match(/entfernt club #{@club.id}/, output)
  end

  test 'Rollback im DRY_RUN ändert nichts' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')

    output = run_task(@rollback)

    assert_match(/DRY RUN/, output)
    assert_equal 1, own_entries(player).size
  end

  test 'nach dem Rollback stellt ein erneuter Lauf den Eintrag wieder her' do
    player = legacy_player
    run_task(@backfill, 'DRY_RUN' => 'false')
    run_task(@rollback, 'DRY_RUN' => 'false')
    assert_empty player.reload.clubs

    run_task(@backfill, 'DRY_RUN' => 'false')

    assert_equal @club.id, own_entries(player).first['club_id']
  end

  test 'der Merge verwirft den Eintrag, wenn der Master denselben Verein aktiv hat' do
    # Regelfall der Gruppe A: genau dafür wird der Verein gesetzt, der offene
    # Heimateintrag des Masters deckt ihn ab (_merge_clubs verwirft die Dopplung).
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    run_task(@backfill, 'DRY_RUN' => 'false')

    player.reload.merge_into!(master, create(:user).id)

    assert_empty own_entries(master), 'am Master bleibt nichts liegen'
    assert_equal 1, master.reload.clubs.size
  end

  test 'der Marker bleibt am deaktivierten Secondary stehen und der Rollback erfasst ihn' do
    player = legacy_player
    master = create(:player, first_name: 'Phillip', last_name: 'Musterberg', birthdate: '1997-09-17',
                             clubs: [home_entry(@club)])
    run_task(@backfill, 'DRY_RUN' => 'false')
    player.reload.merge_into!(master, create(:user).id)
    assert_equal 1, own_entries(player).size, 'deactivate! stempelt nur valid_until'

    run_task(@rollback, 'DRY_RUN' => 'false')

    assert_empty own_entries(player)
  end

  test 'Rollback greift auch beim Master, wenn der Merge den Eintrag weitergegeben hat' do
    # Sonderfall: der Master führt den Verein nur GESCHLOSSEN, also ergänzt
    # _merge_clubs den offenen Backfill-Eintrag statt ihn zu verwerfen. Der Master
    # trägt einen anderen Namen, damit er kein Dubletten-Kandidat ist.
    player = legacy_player
    master = create(:player, first_name: 'Anders', last_name: 'Fremdname', birthdate: '1970-05-05',
                             clubs: [home_entry(@club, created_at: '2013-08-01T00:00:00+02:00',
                                                       valid_until: '2015-07-31T00:00:00+02:00')])
    run_task(@backfill, 'DRY_RUN' => 'false')
    player.reload.merge_into!(master, create(:user).id)
    assert_equal 1, own_entries(master).size, 'merge_into! hängt den Eintrag an den Master'

    run_task(@rollback, 'DRY_RUN' => 'false')

    assert_empty own_entries(master)
    assert_equal 1, master.reload.clubs.size, 'der echte Heimateintrag bleibt'
  end

  # ── CSV ───────────────────────────────────────────────────────────────────

  test 'CSV_DIR schreibt eine Arbeitsliste je Verein in einen Lauf-Unterordner' do
    player = legacy_player
    base = Dir.mktmpdir

    output = run_task(@backfill, 'DRY_RUN' => 'false', 'CSV_DIR' => base)

    run_dirs = Dir.children(base)
    assert_equal 1, run_dirs.size, 'je Lauf ein eigener Unterordner'
    path = File.join(base, run_dirs.first, "#{@club.id}-verein-a.csv")
    assert File.exist?(path)
    rows = CSV.read(path)
    assert_equal %w[player_id nachname vorname geburtsdatum gruppe begruendung dubletten_id], rows.first
    assert_includes rows.map(&:first), player.id.to_s
    assert_match(/CSV-Arbeitslisten/, output)
  ensure
    FileUtils.remove_entry(base) if base
  end

  test 'prepare_csv_dir liefert ohne CSV_DIR nichts' do
    assert_nil HomeClubBackfillTask.prepare_csv_dir(nil)
    assert_nil HomeClubBackfillTask.prepare_csv_dir('')
  end

  # ── Bericht ───────────────────────────────────────────────────────────────

  test 'der Bericht nennt alle vorkommenden Begründungen einer Gruppe' do
    legacy_player
    legacy_player(first_name: 'Ohne', last_name: 'Lizenzlos', birthdate: '1999-09-09').update!(licenses: [])

    output = run_task(@backfill)

    assert_match(/E: /, output)
    assert_match(/Lizenz-Verein/, output)
    assert_match(/G: /, output)
    assert_match(/keine belegende Lizenz/, output)
  end

  test 'der Bericht warnt bei Profilen ohne Altdaten-Merkmal und nennt die PaperTrail-Folge' do
    legacy_player.update!(licenses: [])

    output = run_task(@backfill)

    assert_match(/ohne LIC:-Lizenz/, output)
    assert_match(/PaperTrail-Version/, output)
  end
end
