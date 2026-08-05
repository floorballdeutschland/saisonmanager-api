require 'test_helper'
require 'rake'

# Tests für clubs:fix_state_associations (lib/tasks/fix_club_state_associations.rake).
#
# Der Task schreibt clubs.state_association_id auf Produktion um (Stand 08/2026:
# 63 Vereine). Maßgeblich ist das Bundesland des Vereins, nicht sein
# Spielbetrieb – bestätigt durch die PLZ. Geraten wird nie: was die PLZ nicht
# bestätigt, landet in der Prüfliste.
class FixClubStateAssociationsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    create(:setting, current_season_id: '18')

    # Alle Kürzel der Zuordnungstabelle müssen auflösbar sein, sonst bricht der
    # Task ab (siehe Test unten).
    @associations = ClubStateAssociationResolver::STATE_TO_SA_SHORT.values.uniq.to_h do |short|
      [short, create(:state_association, name: "LV #{short}", short_name: short)]
    end
    @fvd = create(:state_association, name: 'Floorball-Verband Deutschland e.V.', short_name: 'FVD')

    @go = create(:game_operation, state_association_id: @associations['FVNB'].id)
  end

  def run_task(name = 'clubs:fix_state_associations', env = {})
    task = Rake::Task[name]
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # PLZ 26683 liegt in Niedersachsen; der Verein trägt aber Schleswig-Holstein –
  # der Fall STV Sedelsberg.
  def misassigned_club(**attrs)
    create(:club, { name: 'STV Sedelsberg', state: 'de-ni', postcode: '26683',
                    state_association_id: @associations['FLV-SH'].id,
                    game_operations_hash: [{ 'game_operation_id' => @go.id,
                                             'home_game_operation' => true }] }.merge(attrs))
  end

  test 'Dry-Run ist Standard und schreibt nicht' do
    club = misassigned_club

    out, = run_task
    assert_match '[DRY RUN]', out
    assert_match 'ES WURDE NICHTS GESCHRIEBEN', out
    assert_equal @associations['FLV-SH'].id, club.reload.state_association_id
  end

  test 'DRY_RUN=false setzt den Landesverband des Bundeslands' do
    club = misassigned_club

    out, = run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')
    assert_match 'GESCHRIEBEN', out
    assert_equal @associations['FVNB'].id, club.reload.state_association_id
  end

  test 'schreibt updated_at mit, damit Caches die Aenderung sehen' do
    club = misassigned_club
    club.update_columns(updated_at: 2.years.ago)

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_operator club.reload.updated_at, :>, 1.hour.ago
  end

  # Hamburger Vereine im SH-Spielbetrieb: der Spielbetrieb bleibt, der
  # Landesverband wechselt zum Floorball Bund Hamburg.
  test 'korrigiert Vereine, deren Landesverband dem Spielbetrieb statt dem Bundesland folgt' do
    club = create(:club, name: 'SVE Hamburg', state: 'de-hh', postcode: '22523',
                         state_association_id: @associations['FLV-SH'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FBH'].id, club.reload.state_association_id
  end

  # ETV Hamburg: Landesverband Hamburg, Spielbetrieb Niedersachsen. Das ist
  # gewollt und darf nicht angefasst werden.
  test 'laesst Vereine unangetastet, deren Bundesland zum Landesverband passt' do
    club = create(:club, name: 'ETV Hamburg', state: 'de-hh', postcode: '20144',
                         state_association_id: @associations['FBH'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FBH'].id, club.reload.state_association_id
  end

  test 'haengt Vereine am Dachverband an den zustaendigen Unterverband um' do
    dach = create(:state_association, name: 'SBK Ost', short_name: 'SBKOST')
    @associations['FVS'].update!(parent_id: dach.id)
    club = create(:club, name: 'SC DHfK Leipzig', state: 'de-sn', postcode: '04105',
                         state_association_id: dach.id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVS'].id, club.reload.state_association_id
  end

  # Mecklenburg-Vorpommern hat keinen eigenen Landesverband. Nicht raten.
  test 'ueberspringt Bundeslaender ohne eigenen Landesverband und listet sie auf' do
    club = create(:club, name: 'Pommerhoc Greifswald', state: 'de-mv', postcode: '17489',
                         state_association_id: @associations['FVBB'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    out, = run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVBB'].id, club.reload.state_association_id
    assert_match 'ohne eigenen Landesverband', out
    assert_match club.id.to_s, out
  end

  test 'ueberspringt Vereine, deren PLZ das Bundesland nicht bestaetigt' do
    # PLZ liegt in Bayern, hinterlegt ist Niedersachsen – widersprüchlich.
    club = create(:club, name: 'Unklar', state: 'de-ni', postcode: '80331',
                         state_association_id: @associations['FLV-SH'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    out, = run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FLV-SH'].id, club.reload.state_association_id
    assert_match 'PLZ das Bundesland nicht', out
  end

  # Der eigentliche Grund für die Stellenzahl-Prüfung: "6020" (Innsbruck) und
  # "06020" (Sachsen-Anhalt) ergeben denselben Integer. Ohne die Prüfung würde
  # Innsbruck nach Sachsen-Anhalt wandern.
  test 'verschiebt eine vierstellige PLZ nicht automatisch, sondern listet sie auf' do
    club = create(:club, name: 'Hot Shots Innsbruck', state: 'de-st', postcode: '6020',
                         state_association_id: @associations['FVB'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    out, = run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVB'].id, club.reload.state_association_id,
                 'Vierstellige PLZ darf nicht automatisch als Ausland gelten'
    assert_match 'Ausland oder fehlende fuehrende Null', out
  end

  test 'eine deutsche PLZ ohne fuehrende Null wandert nicht ins Ausland' do
    # "6118" ist Halle (Saale) ohne führende Null – kein Auslandsverein.
    club = create(:club, name: 'USV Halle', state: 'de-st', postcode: '6118',
                         state_association_id: @associations['FVSA'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVSA'].id, club.reload.state_association_id
  end

  test 'FOREIGN_CLUB_IDS verschiebt benannte Auslandsvereine auf die Bundesebene' do
    club = create(:club, name: 'Hot Shots Innsbruck', state: 'de-st', postcode: '6020',
                         state_association_id: @associations['FVB'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    out, = run_task('clubs:fix_state_associations',
                    'DRY_RUN' => 'false', 'FOREIGN_CLUB_IDS' => club.id.to_s)

    assert_equal @fvd.id, club.reload.state_association_id
    assert_match 'Ausland -> Bundesebene', out
  end

  # PLZ mit anhängendem Leerzeichen kommt in Produktion vor ('06118 ').
  test 'toleriert Leerzeichen in der PLZ' do
    club = create(:club, name: 'USV Halle', state: 'de-st', postcode: '06118 ',
                         state_association_id: @associations['FVBB'].id,
                         game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVSA'].id, club.reload.state_association_id
  end

  test 'korrigiert auch deaktivierte Vereine' do
    club = misassigned_club(deactivated_at: Time.current)

    run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false')

    assert_equal @associations['FVNB'].id, club.reload.state_association_id
  end

  test 'bricht ab, wenn ein Landesverband der Zuordnungstabelle fehlt' do
    misassigned_club
    @associations['FVNB'].destroy!

    assert_raises(SystemExit) { run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false') }
  end

  # Ohne Bundesverband liefe der Ausland-Zweig auf nil.id – der Lauf würde
  # mitten im Schreiben abbrechen.
  test 'bricht ab, wenn der Bundesverband fehlt' do
    misassigned_club
    @fvd.destroy!

    assert_raises(SystemExit) { run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false') }
  end

  # short_name hat keinen Unique-Index. Bei Dopplung entschiede die Ladereihenfolge
  # über 63 Schreibvorgänge.
  test 'bricht bei mehrfach vergebenem Kuerzel ab' do
    misassigned_club
    create(:state_association, name: 'Zweiter FVNB', short_name: 'FVNB')

    assert_raises(SystemExit) { run_task('clubs:fix_state_associations', 'DRY_RUN' => 'false') }
  end

  test 'bricht bei unklarem DRY_RUN-Wert ab, statt still nichts zu tun' do
    club = misassigned_club

    assert_raises(SystemExit) { run_task('clubs:fix_state_associations', 'DRY_RUN' => 'False') }
    assert_equal @associations['FLV-SH'].id, club.reload.state_association_id
  end

  test 'Report laeuft ohne Abweichungen durch und schreibt nie' do
    club = misassigned_club

    out, = run_task('clubs:state_association_report')

    assert_match club.id.to_s, out
    assert_match 'mit Abweichung', out
    assert_equal @associations['FLV-SH'].id, club.reload.state_association_id
  end

  # Report und Fix-Task müssen denselben Bestand betrachten, sonst zeigt die
  # Vorschau etwas anderes als der Lauf ändert.
  test 'Report zeigt dieselben Vereine wie der Fix-Task, inklusive deaktivierter' do
    aktiv = misassigned_club
    inaktiv = misassigned_club(name: 'Deaktiviert', deactivated_at: Time.current)

    report, = run_task('clubs:state_association_report')
    fix, = run_task

    [aktiv, inaktiv].each do |club|
      assert_match club.id.to_s, report
      assert_match club.id.to_s, fix
    end
  end
end
