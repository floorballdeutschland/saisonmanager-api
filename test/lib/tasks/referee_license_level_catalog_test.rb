require 'test_helper'
require 'rake'

# Tests fuer referees:license_level_catalog (lib/tasks/referee_license_level_catalog.rake):
# Positionen setzen, fehlende Stufe N4 anlegen, Kursnamen im Stufenfeld korrigieren.
class RefereeLicenseLevelCatalogTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['referees:license_level_catalog']
    @task.reenable
    create(:setting, current_season_id: '19')
    RefereeLicenseLevel.delete_all
    %w[N1 N2 N3 L1 L2 L3 LJ].each { |n| RefereeLicenseLevel.create!(name: n, validity_years: 1) }
  end

  def run_task(dry_run: false)
    ENV['DRY_RUN'] = dry_run ? '1' : nil
    @task.reenable
    out, = capture_io { @task.invoke }
    out
  ensure
    ENV.delete('DRY_RUN')
  end

  test 'setzt die Positionen in der Rangfolge N vor L, LJ zuletzt' do
    run_task

    assert_equal [%w[N1], %w[N2], %w[N3], %w[N4], %w[L1], %w[L2], %w[L3], %w[LJ]].flatten,
                 RefereeLicenseLevel.order(:position).pluck(:name)
  end

  test 'legt N4 inaktiv an, mit einem Jahr Gueltigkeit' do
    run_task

    n4 = RefereeLicenseLevel.find_by(name: 'N4')

    assert_not_nil n4
    assert_not n4.active
    assert_equal 1, n4.validity_years
    assert_equal 4, n4.position
  end

  # G3 ist der Kurs, der zur L3 fuehrt -- keine Lizenzstufe. Der Wert steht in
  # den Kursergebnissen und wandert von dort auf den Schiedsrichter.
  test 'korrigiert Kursnamen und Kleinschreibung in beiden Tabellen' do
    schiri = create(:referee, lizenzstufe: 'G3')
    klein = create(:referee, lizenzstufe: 'l1')
    ergebnis = kursergebnis('G3')

    run_task

    assert_equal 'L3', schiri.reload.lizenzstufe
    assert_equal 'L1', klein.reload.lizenzstufe
    assert_equal 'L3', ergebnis.reload.lizenzstufe
  end

  # Ohne diesen Schritt entstuenden aus den Kursergebnissen wieder Schiedsrichter
  # mit einer Stufe, die der Katalog nicht kennt.
  test 'benennt die abweichende Gueltigkeitsdauer bei G2 auf L2' do
    RefereeLicenseLevel.find_by(name: 'L2').update!(validity_years: 2)
    kursergebnis('G2')

    out = run_task(dry_run: true)

    assert_match(/G2\s+-> L2/, out)
    assert_match(/ACHTUNG: Gueltigkeitsdauer 1 -> 2/, out)
  end

  test 'DRY_RUN schreibt nichts' do
    schiri = create(:referee, lizenzstufe: 'G3')

    out = run_task(dry_run: true)

    assert_match(/DRY RUN/, out)
    assert_nil RefereeLicenseLevel.find_by(name: 'N4')
    assert_nil RefereeLicenseLevel.find_by(name: 'N1').position
    assert_equal 'G3', schiri.reload.lizenzstufe
  end

  test 'ein zweiter Lauf findet nichts mehr zu tun' do
    create(:referee, lizenzstufe: 'G3')
    run_task

    out = run_task

    assert_match(/Fehlende Stufen: keine/, out)
    assert_equal 2, out.scan('nichts zu tun').size
    assert_match(/0 Stufe\(n\) angelegt, 0 Position\(en\) gesetzt/, out)
  end

  # Der Lauf soll zeigen, was er nicht entscheiden kann, statt es zu verschweigen.
  test 'meldet Stufen, die weder im Katalog noch in der Korrekturliste stehen' do
    create(:referee, lizenzstufe: 'X9')

    out = run_task

    assert_match(/Unbekannte Stufen bleiben stehen/, out)
    assert_match(/"X9"=>1/, out)
  end

  private

  def kursergebnis(stufe)
    import = RefereeCourseImport.create!(
      uploaded_by_user_id: (@user ||= create(:user)).id,
      filename: "kurs_#{SecureRandom.hex(3)}.csv", status: 'in_review'
    )
    RefereeCourseResult.create!(referee_course_import: import, lizenzstufe: stufe,
                                csv_vorname: 'Test', csv_nachname: 'Person',
                                match_type: RefereeCourseResult::MATCH_TYPES.first)
  end
end
