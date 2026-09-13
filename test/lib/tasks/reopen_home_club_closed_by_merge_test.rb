require 'test_helper'
require 'rake'

# Tests fuer players:reopen_home_club_closed_by_merge
# (lib/tasks/reopen_home_club_closed_by_merge.rake): oeffnet den Heimatverein wieder, den
# eine Zusammenlegung am Tag eines Vereinswechsels geschlossen hat und der das Profil ganz
# ohne Verein zurueckliess (Spieler 1047, 09.09.2026).
class ReopenHomeClubClosedByMergeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:reopen_home_club_closed_by_merge']
    @task.reenable

    create(:setting, current_season_id: '18')
    @user = create(:user)
    @alt = create(:club, name: 'Berlin Rockets')
    @neu = create(:club, name: 'SSV Rapid')
  end

  def run_task(env = {})
    env = { 'USER_ID' => @user.id.to_s, 'DRY_RUN' => 'false' }.merge(env)
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def heimat(club, created_at, valid_until: nil, valid_set_by: nil)
    eintrag = { 'club_id' => club.id, 'home_club' => true, 'created_at' => created_at.iso8601 }
    eintrag['valid_until'] = valid_until.iso8601 if valid_until
    eintrag['valid_set_by'] = valid_set_by if valid_set_by
    eintrag
  end

  # Der Bestand von 1047: alter Verein durch den Transfer beendet, neuer Verein kurz
  # darauf durch die Zusammenlegung -- und die hat ihren Vermerk am alten Eintrag
  # hinterlassen.
  def profil_ohne_verein(merge_um: 7.minutes.ago, wechsel_um: 14.minutes.ago, merge_user: nil)
    merge_user ||= @user
    player = create(:player, clubs: [
      heimat(@alt, 10.years.ago, valid_until: wechsel_um, valid_set_by: merge_user.id)
      .merge(Player::HOME_CLUB_DECIDED_BY => Player::DECIDED_BY_LICENSE),
      heimat(@neu, wechsel_um, valid_until: merge_um, valid_set_by: merge_user.id)
    ])
    MergeLog.create!(object_type: 'player', master_id: player.id, master_label: 'Lordieck, Ole',
                     merged_id: create(:player).id, merged_label: 'Lordieck, Ole',
                     performed_by_user_id: merge_user.id, created_at: merge_um)
    player
  end

  test 'oeffnet den vom Merge geschlossenen Heimatverein' do
    player = profil_ohne_verein
    # Nicht ueber `home_club_entry`: Der Leser vergleicht tagesgenau und nennt den heute
    # geschlossenen Eintrag bis Mitternacht weiter. Genau deshalb faellt der Schaden erst
    # am naechsten Tag auf. Massgeblich ist der gespeicherte Zustand.
    assert_empty player.clubs.reject { |c| c['valid_until'].present? },
                 'Vorbedingung: das Profil hat keinen offenen Verein'

    run_task
    player.reload

    offen = player.clubs.select { |c| c['valid_until'].blank? }
    assert_equal([@neu.id], offen.map { |c| c['club_id'] })
    assert_equal @neu.id, player.home_club_entry['club_id']
    assert_equal @user.id, player.updated_by
  end

  # Riegel 2: Der Transfer selbst bleibt stehen. Wuerde der Lauf den aelteren Eintrag
  # oeffnen, behauptete er eine Mitgliedschaft, die regulaer geendet hat.
  test 'laesst den vom Transfer geschlossenen Eintrag geschlossen' do
    wechsel_um = 14.minutes.ago
    player = profil_ohne_verein(wechsel_um: wechsel_um)

    run_task
    player.reload

    alt = player.clubs.find { |c| c['club_id'] == @alt.id }
    assert_equal wechsel_um.iso8601, alt['valid_until']
    assert_nil alt[Player::HOME_CLUB_DECIDED_BY],
               'der Vermerk ueber die aufgehobene Wahl muss weg sein'
  end

  # Riegel 1: Ein Profil mit laufendem Heimatverein hat das Problem nicht. Einen zweiten zu
  # oeffnen brauechte genau die Doppeldeutigkeit, gegen die der Merge-Riegel existiert.
  test 'fasst ein Profil mit laufendem Heimatverein nicht an' do
    player = create(:player, clubs: [
      heimat(@alt, 10.years.ago, valid_until: 14.minutes.ago, valid_set_by: @user.id),
      heimat(@neu, 14.minutes.ago)
    ])
    MergeLog.create!(object_type: 'player', master_id: player.id, master_label: 'x',
                     merged_id: create(:player).id, merged_label: 'x',
                     performed_by_user_id: @user.id, created_at: 7.minutes.ago)
    vorher = player.clubs.deep_dup

    run_task
    player.reload

    assert_equal vorher, player.clubs
  end

  # Riegel 3: Ohne Merge-Stempel wird gemeldet statt geschrieben. Ein Profil kann aus ganz
  # anderen Gruenden ohne Verein dastehen -- Austritt, Ablage, Altbestand.
  test 'oeffnet ohne Merge-Stempel nichts und meldet den Fall' do
    player = create(:player, clubs: [heimat(@alt, 10.years.ago, valid_until: 3.years.ago)])
    MergeLog.create!(object_type: 'player', master_id: player.id, master_label: 'x',
                     merged_id: create(:player).id, merged_label: 'x',
                     performed_by_user_id: @user.id, created_at: 7.minutes.ago)
    vorher = player.clubs.deep_dup

    ausgabe, = run_task
    player.reload

    assert_equal vorher, player.clubs
    assert_match(/bitte pruefen/, ausgabe)
  end

  test 'der Dry-Run schreibt nichts' do
    player = profil_ohne_verein
    vorher = player.clubs.deep_dup

    ausgabe, = run_task({ 'DRY_RUN' => 'true' })
    player.reload

    assert_equal vorher, player.clubs
    assert_match(/SSV Rapid/, ausgabe)
    assert_match(/Dry-Run/, ausgabe)
  end

  test 'PLAYER_IDS grenzt den Lauf ein' do
    betroffen = profil_ohne_verein
    anderer = profil_ohne_verein
    vorher = anderer.clubs.deep_dup

    run_task({ 'PLAYER_IDS' => betroffen.id.to_s })

    assert_nil betroffen.reload.clubs.find { |c| c['club_id'] == @neu.id }['valid_until']
    assert_equal vorher, anderer.reload.clubs
  end

  # Ein zweiter Lauf darf nichts mehr tun: Nach dem ersten laeuft wieder ein Heimatverein,
  # und damit greift Riegel 1.
  test 'ist wiederholbar' do
    player = profil_ohne_verein

    run_task
    nach_erstem = player.reload.clubs.deep_dup
    run_task

    assert_equal nach_erstem, player.reload.clubs
  end
end
