require 'test_helper'
require 'rake'

# Tests für lib/tasks/backfill_profile_releases.rake. Der Lauf trägt die
# Vorgangszeilen für Freigaben nach, die vor api#572 über das Spielerprofil
# erteilt wurden und deshalb in der Übersicht „Transferanträge" fehlten.
#
# Der Schwerpunkt liegt auf dem, was der Lauf ABLEITEN muss: den abgebenden
# Verein und die Frage, ob eine beendete Freigabe widerrufen oder regulär
# ausgelaufen ist. Beides steht nicht im clubs-Eintrag.
class BackfillProfileReleasesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['transfers:backfill_profile_releases']
    @task.reenable

    create(:setting, current_season_id: '18')
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @home_club = create(:club, game_operation: @go)
    @target = create(:club, game_operation: @go)
    @sbk = create(:user, :admin)

    @seit = 3.weeks.ago
    @freigabe_am = 2.weeks.ago
  end

  def run_task(env = {})
    env = { 'SINCE' => @seit.strftime('%Y-%m-%d') }.merge(env)
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # Ein Profil mit laufendem Heimatverein und einer im Profil erteilten Freigabe.
  def profil_mit_freigabe(valid_until: regulaeres_ende, erteilt_am: @freigabe_am, heimat_bis: nil)
    create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true,
        'created_at' => 1.year.ago.iso8601, 'valid_until' => heimat_bis },
      { 'club_id' => @target.id, 'home_club' => false, 'created_by' => @sbk.id,
        'valid_set_by' => @sbk.id, 'created_at' => erteilt_am.iso8601,
        'valid_until' => valid_until }
    ])
  end

  # Beginn der laufenden Spielzeit -- dieselbe Regel wie im Lauf.
  def saisonbeginn
    beginn = Time.zone.local(Date.current.year, 7, 1)
    beginn -= 1.year if beginn > Time.current
    beginn
  end

  # Das reguläre Ende, das beide Schreibwege setzen: 15.07., 00:00 Uhr Ortszeit.
  def regulaeres_ende
    ende = Date.new(Date.today.year, 7, 15).to_time
    ende += 1.year if ende < Time.now
    ende.iso8601(3)
  end

  test 'Dry-Run schreibt nichts' do
    profil_mit_freigabe

    assert_no_difference -> { TransferRequest.count } do
      run_task
    end
  end

  test 'trägt den Vorgang mit abgeleitetem abgebendem Verein nach' do
    player = profil_mit_freigabe

    assert_difference -> { TransferRequest.count }, 1 do
      run_task('DRY_RUN' => 'false')
    end

    tr = TransferRequest.last
    assert_equal player.id, tr.player_id
    assert_equal @target.id, tr.requesting_club_id
    assert_equal @home_club.id, tr.former_club_id, 'abgebend ist der zum Zeitpunkt laufende Heimatverein'
    assert_equal 'release', tr.request_type
    assert_equal 'approved', tr.status
    assert tr.direct
    assert_equal @sbk.id, tr.created_by
    assert_equal @sbk.id, tr.approved_by_lv_user_id
    assert_equal 18, tr.season_id
    assert_nil tr.player_confirmation_token
    assert_in_delta @freigabe_am.to_i, tr.created_at.to_i, 5,
                    'der Vorgang trägt das Datum der Freigabe, nicht das des Laufs'
  end

  test 'ein zweiter Lauf legt nichts doppelt an' do
    profil_mit_freigabe
    run_task('DRY_RUN' => 'false')

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  # Freigaben aus dem Antragsweg tragen ihren Vorgang bereits. Erkannt werden sie
  # über `lv_approved_at` -- angelegt wurde der Vorgang beim Stellen, geschrieben
  # der clubs-Eintrag erst beim Genehmigen.
  test 'Freigabe aus dem Antragsweg wird nicht doppelt angelegt' do
    player = profil_mit_freigabe
    TransferRequest.create!(
      player_id: player.id, requesting_club_id: @target.id, former_club_id: @home_club.id,
      status: 'approved', request_type: 'release', created_by: @sbk.id,
      approved_by_lv_user_id: @sbk.id, lv_approved_at: @freigabe_am,
      created_at: @freigabe_am - 5.days, season_id: 18
    )

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  test 'vorzeitig beendete Freigabe entsteht als Widerruf' do
    beendet_am = 3.days.ago
    profil_mit_freigabe(valid_until: beendet_am.iso8601)

    run_task('DRY_RUN' => 'false')

    tr = TransferRequest.last
    assert_equal 'revoked', tr.status
    assert_equal @sbk.id, tr.revoked_by
    assert_in_delta beendet_am.to_i, tr.revoked_at.to_i, 5
    assert_equal 'Freigabe im Spielerprofil beendet', tr.revocation_reason
  end

  # Gegenprobe: Auslaufen am Stichtag ist kein Widerruf. Der Zeitstempel trägt den
  # Versatz der schreibenden Zone -- mit `Time.zone.parse` in die Anwendungszone
  # (UTC) umgerechnet wäre aus Berliner Mitternacht der 14.07., 22:00 Uhr
  # geworden, und der Lauf hätte einen Widerruf erfunden, den es nie gab.
  #
  # Der Eintrag liegt bewusst kurz nach Saisonbeginn: Weiter zurück reicht der
  # Lauf nicht, er stempelt die laufende Saison. Zwischen dem 1. und dem 15. Juli
  # ist der Stichtag noch nicht vergangen, dann gilt die Freigabe schlicht als
  # laufend -- die Zusicherung bleibt richtig, prüft aber weniger.
  test 'am Stichtag ausgelaufene Freigabe bleibt genehmigt' do
    stichtag = Date.new(saisonbeginn.year, 7, 15)
    profil_mit_freigabe(erteilt_am: saisonbeginn + 2.days,
                        valid_until: "#{stichtag.iso8601}T00:00:00.000+02:00")

    run_task('DRY_RUN' => 'false', 'SINCE' => saisonbeginn.strftime('%Y-%m-%d'))

    assert_equal 'approved', TransferRequest.last.status
  end

  # Der Lauf stempelt jede Zeile mit der LAUFENDEN Saison. Reichte SINCE weiter
  # zurück, bekämen ältere Freigaben die falsche -- und das bliebe unsichtbar,
  # weil die Lizenzliste nach der Saison der Liga aufschlüsselt.
  test 'SINCE vor dem Saisonbeginn wird abgewiesen' do
    profil_mit_freigabe

    assert_raises(SystemExit) do
      run_task('DRY_RUN' => 'false', 'SINCE' => (saisonbeginn - 2.months).strftime('%Y-%m-%d'))
    end
  end

  # Ein handelndes Konto, das es nicht gibt: `.to_i` hätte daraus stillschweigend
  # Konto 0 gemacht -- ein Vorgang, dessen Urheber in der Übersicht leer bleibt.
  test 'unbekanntes handelndes Konto wird übersprungen' do
    create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 },
      { 'club_id' => @target.id, 'home_club' => false, 'created_by' => 999_999,
        'created_at' => @freigabe_am.iso8601, 'valid_until' => regulaeres_ende }
    ])

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  # Ein vorhandenes, aber unlesbares Enddatum wird nicht ausgelegt: Beide
  # Auslegungen schrieben etwas Falsches -- eine Freigabe, die es nicht gibt,
  # oder einen erfundenen Widerruf.
  test 'unlesbares Enddatum wird übersprungen' do
    profil_mit_freigabe(valid_until: 'bis auf Weiteres')

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  test 'ohne eindeutigen Heimatverein wird übersprungen' do
    create(:player, clubs: [
      { 'club_id' => @target.id, 'home_club' => false, 'created_by' => @sbk.id,
        'created_at' => @freigabe_am.iso8601, 'valid_until' => regulaeres_ende }
    ])

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  test 'zwei offene Heimatvereine sind mehrdeutig und werden übersprungen' do
    zweiter = create(:club, game_operation: @go)
    create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 },
      { 'club_id' => zweiter.id, 'home_club' => true, 'created_at' => 6.months.ago.iso8601 },
      { 'club_id' => @target.id, 'home_club' => false, 'created_by' => @sbk.id,
        'created_at' => @freigabe_am.iso8601, 'valid_until' => regulaeres_ende }
    ])

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  # Der Heimatverein, der zum Zeitpunkt der Freigabe lief, ist nicht zwingend der
  # heutige: Ein späterer Vereinswechsel darf den Vorgang nicht umschreiben.
  test 'maßgeblich ist der Heimatverein zum Zeitpunkt der Freigabe' do
    spaeterer = create(:club, game_operation: @go)
    create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601,
        'valid_until' => 1.week.ago.iso8601 },
      { 'club_id' => spaeterer.id, 'home_club' => true, 'created_at' => 1.week.ago.iso8601 },
      { 'club_id' => @target.id, 'home_club' => false, 'created_by' => @sbk.id,
        'created_at' => @freigabe_am.iso8601, 'valid_until' => regulaeres_ende }
    ])

    run_task('DRY_RUN' => 'false')

    assert_equal @home_club.id, TransferRequest.last.former_club_id
  end

  test 'Eintraege vor dem Zeitraum bleiben unberuehrt' do
    profil_mit_freigabe(erteilt_am: 8.weeks.ago)

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end

  test 'ohne handelndes Konto wird übersprungen' do
    create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 },
      { 'club_id' => @target.id, 'home_club' => false,
        'created_at' => @freigabe_am.iso8601, 'valid_until' => regulaeres_ende }
    ])

    assert_no_difference -> { TransferRequest.count } do
      run_task('DRY_RUN' => 'false')
    end
  end
end
