require 'test_helper'
require 'rake'

# Tests fuer clubs:fbh_under_flvsh und clubs:responsibility_report
# (lib/tasks/align_club_responsibility.rake).
#
# Der erste Task haengt den Floorball Bund Hamburg unter den FLV-SH, damit die
# sechs Hamburger Vereine nach der Umstellung einen zustaendigen Spielbetrieb
# haben. Ohne ihn koennte fuer sie niemand berechtigt werden: `permissions`
# kennen nur `game_operation_id`, und Hamburg hat keinen Spielbetrieb.
#
# Verbaende werden hier ueber ihre Kuerzel angelegt, weil der Task sie so sucht.
class AlignClubResponsibilityTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')

    @flvsh = create(:state_association, name: 'Floorballverband Schleswig-Holstein e.V.',
                                        short_name: 'FLV-SH', sbk_email: 'sbk@floorball-sh.example')
    @flvsh_go = create(:game_operation, state_association_id: @flvsh.id)
    @fbh = create(:state_association, name: 'Floorball Bund Hamburg e.V.', short_name: 'FBH',
                                      sbk_email: 'info@floorball.hamburg',
                                      vsk_email: 'info@floorball.hamburg',
                                      rsk_email: 'info@floorball.hamburg')
  end

  def run_task(name, dry_run: false)
    task = Rake::Task[name]
    saved = ENV.fetch('DRY_RUN', nil)
    ENV['DRY_RUN'] = dry_run ? 'true' : 'false'
    task.reenable
    capture_io { task.invoke }
  ensure
    ENV['DRY_RUN'] = saved
  end

  test 'haengt FBH unter den FLV-SH und macht dessen Spielbetrieb zustaendig' do
    club = create(:club, state_association_id: @fbh.id)
    assert_nil club.main_game_operation_id, 'Ausgangslage: kein Verband zustaendig'

    run_task('clubs:fbh_under_flvsh')

    assert_equal @flvsh.id, @fbh.reload.parent_id
    assert_equal @flvsh_go.id, club.reload.main_game_operation_id
  end

  # Die Postfaecher sollen auf den FLV-SH zurueckfallen. Das tun sie nur bei
  # leerem eigenem Feld (StateAssociation#effective_sbk_email und Geschwister) --
  # ein eigener Eintrag am Kind gewinnt und haette die Post weiter nach Hamburg
  # geschickt, obwohl zustaendig der FLV-SH ist.
  test 'leert die Postfaecher, damit sie vom FLV-SH geerbt werden' do
    run_task('clubs:fbh_under_flvsh')
    @fbh.reload

    assert_nil @fbh.sbk_email
    assert_nil @fbh.vsk_email
    assert_nil @fbh.rsk_email
    assert_equal 'sbk@floorball-sh.example', @fbh.effective_sbk_email
  end

  test 'Dry-Run schreibt nichts' do
    run_task('clubs:fbh_under_flvsh', dry_run: true)
    @fbh.reload

    assert_nil @fbh.parent_id
    assert_equal 'info@floorball.hamburg', @fbh.sbk_email
  end

  # Ohne Spielbetrieb am Ziel waere Hamburg nach dem Lauf genauso herrenlos wie
  # vorher, nur mit einem Elternverband. Der Task bricht dann ab, statt eine
  # Aenderung zu schreiben, die ihren Zweck verfehlt.
  test 'bricht ab, wenn der FLV-SH keinen Spielbetrieb hat' do
    @flvsh_go.destroy!

    assert_raises(SystemExit) { run_task('clubs:fbh_under_flvsh') }
    assert_nil @fbh.reload.parent_id
  end

  # Der Bericht ist das Tor vor dem Deploy: Jede Zeile ist ein Verein, der seinen
  # Verband wechselt, ohne dass es jemand angeordnet hat.
  test 'Bericht nennt Vereine, deren Zustaendigkeit sich verschiebt' do
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)
    # Gespeichert der fremde Spielbetrieb, abgeleitet der des eigenen Verbands:
    # genau die Lage des ETV Hamburg vor der Umstellung.
    wechsler = create(:club, name: 'Wechsler', state_association_id: @flvsh.id,
                             game_operations_hash: [{ 'game_operation_id' => fremd_go.id,
                                                      'home_game_operation' => true }])

    out, = run_task('clubs:responsibility_report')

    assert_match(/Zustaendigkeit wechselt \(1\)/, out)
    assert_match(/#{wechsler.id}\s+Wechsler/, out)
  end

  test 'Bericht nennt Vereine ohne zustaendigen Verband samt Ursache' do
    ohne_lv = create(:club, name: 'Ohne LV', state_association_id: nil)
    verbund_ohne_go = create(:club, name: 'Verbund ohne GO', state_association_id: @fbh.id)

    out, = run_task('clubs:responsibility_report')

    assert_match(/Kein Verband zustaendig \(2\)/, out)
    assert_match(/#{ohne_lv.id}\s+Ohne LV\s+.*kein Landesverband/, out)
    assert_match(/#{verbund_ohne_go.id}\s+Verbund ohne GO\s+.*Verbund ohne Spielbetrieb/, out)
  end
end
