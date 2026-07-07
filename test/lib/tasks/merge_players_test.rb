require 'test_helper'
require 'rake'

# Tests für lib/tasks/merge_players.rake bzw. das Helfermodul PlayerMergeHelper:
# Duplikat-Erkennung (Name + ähnliches Geburtsdatum), Auflösung des
# verbleibenden Geburtsdatums und der verlustfreie Live-Merge in die kleinste ID.
class MergePlayersTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:merge_duplicates']
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

  # --- Datums-Ähnlichkeit ----------------------------------------------------

  test 'similar_dates? erkennt identisch, +-1 Tag und Ein-Ziffer-Abweichung' do
    d = ->(s) { Date.parse(s) }
    assert PlayerMergeHelper.similar_dates?(d['1990-05-14'], d['1990-05-14'])
    assert PlayerMergeHelper.similar_dates?(d['1990-05-14'], d['1990-05-15']), '+-1 Tag'
    assert PlayerMergeHelper.similar_dates?(d['1972-03-15'], d['1872-03-15']), 'Jahres-Tippfehler'
    refute PlayerMergeHelper.similar_dates?(d['1990-05-14'], d['1985-11-02']), 'echte Verschiedenheit'
  end

  test 'one_digit_diff? nur bei genau einer abweichenden Ziffer' do
    assert PlayerMergeHelper.one_digit_diff?('1972-03-15', '1872-03-15')
    refute PlayerMergeHelper.one_digit_diff?('1972-03-15', '1972-03-15')
    refute PlayerMergeHelper.one_digit_diff?('1990-05-19', '1990-05-20'), 'zwei Ziffern abweichend'
  end

  # --- Auflösung des Geburtsdatums ------------------------------------------

  test 'resolve_birthdate bevorzugt plausibles Jahr' do
    a = build_player(birthdate: '1872-03-15')
    b = build_player(birthdate: '1972-03-15')
    assert_equal '1972-03-15', PlayerMergeHelper.resolve_birthdate([a, b])
  end

  test 'resolve_birthdate nimmt bei Tagesabweichung das fruehere Datum' do
    a = build_player(birthdate: '1990-01-02')
    b = build_player(birthdate: '1990-01-01')
    assert_equal '1990-01-01', PlayerMergeHelper.resolve_birthdate([a, b])
  end

  # --- Gruppierung -----------------------------------------------------------

  test 'find_duplicate_groups gruppiert gleichnamige mit aehnlichem Geburtsdatum' do
    keep = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1972-03-15')
    dup  = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1872-03-15')
    # Gleicher Name, aber deutlich anderes Geburtsdatum → kein Duplikat.
    create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1960-08-01')

    groups = PlayerMergeHelper.find_duplicate_groups
    group = groups.find { |survivor, _| survivor.id == keep.id }

    assert group, 'Gruppe mit kleinster ID als Survivor erwartet'
    assert_equal [dup.id], group.last.map(&:id)
  end

  test 'find_duplicate_groups ignoriert bereits zusammengefuehrte Spieler' do
    target = create(:player, first_name: 'Ziel', last_name: 'Person', birthdate: '1980-01-01')
    create(:player, first_name: 'Anna', last_name: 'Test', birthdate: '1995-06-06',
                    merged_into_id: target.id, deactivated_at: Time.current)
    create(:player, first_name: 'Anna', last_name: 'Test', birthdate: '1995-06-06')

    assert_empty PlayerMergeHelper.find_duplicate_groups
  end

  # --- Live-Merge ------------------------------------------------------------

  test 'Live-Merge fuehrt in die kleinste ID zusammen und loest Geburtsdatum auf' do
    keep = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1872-03-15')
    dup  = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1972-03-15')

    run_task('DRY_RUN' => 'false')

    assert_nil   keep.reload.merged_into_id, 'kleinste ID bleibt bestehen'
    assert_nil   keep.deactivated_at
    assert_equal '1972-03-15', keep.birthdate, 'plausibles Jahr uebernommen'
    assert_equal keep.id, dup.reload.merged_into_id
    assert_not_nil dup.deactivated_at
  end

  test 'DRY_RUN veraendert keine Daten' do
    keep = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1972-03-15')
    dup  = create(:player, first_name: 'Max', last_name: 'Muster', birthdate: '1972-03-16')

    run_task('DRY_RUN' => 'true')

    assert_nil dup.reload.merged_into_id
    assert_nil keep.reload.merged_into_id
  end

  private

  def build_player(attrs)
    Player.new({ first_name: 'Max', last_name: 'Muster' }.merge(attrs))
  end
end
