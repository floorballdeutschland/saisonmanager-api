require 'test_helper'

# Die drei Scopes des zeilenweisen Einreichens (#631). Sie teilen die Zeilen
# eines Imports auf, und jede falsche Grenze hat eine eigene Folge: Eine Zeile
# zu viel in `submittable` wird doppelt angewendet, eine zu viel in
# `open_for_importer` haelt den Import fuer immer offen.
class RefereeCourseResultTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @admin = create(:user, :admin)
    @import = RefereeCourseImport.create!(
      uploaded_by_user: @admin, filename: 'kurs.csv', total_rows: 0, status: 'in_review'
    )
  end

  def result(status:, deferred: false, submitted: false)
    RefereeCourseResult.create!(
      referee_course_import: @import,
      status: status,
      deferred: deferred,
      submitted_at: (Time.current if submitted),
      match_type: 'new_entry',
      match_field_count: 0,
      csv_vorname: 'V', csv_nachname: 'N'
    )
  end

  test 'die drei Scopes teilen die offenen Zeilen lueckenlos und disjunkt' do
    einreichbar = result(status: 'pending_review')
    zurueckgestellt = result(status: 'pending_review', deferred: true)

    assert_equal [einreichbar.id], @import.referee_course_results.submittable.ids
    assert_equal [zurueckgestellt.id], @import.referee_course_results.deferred.ids
    assert_equal [einreichbar.id, zurueckgestellt.id].sort,
                 @import.referee_course_results.open_for_importer.ids.sort
  end

  # Alles, was der Submit angefasst hat, ist aus der Hand des Importeurs --
  # egal ob angewendet oder beim Landesverband wartend.
  test 'eingereichte Zeilen sind in keinem der drei Scopes' do
    result(status: 'applied', submitted: true)
    result(status: 'pending_review', submitted: true)

    assert_empty @import.referee_course_results.submittable
    assert_empty @import.referee_course_results.deferred
    assert_empty @import.referee_course_results.open_for_importer
  end

  # Die verworfene Zeile ist der Grund fuer den Statusfilter in allen drei
  # Scopes: Sie traegt kein `submitted_at` und wuerde sonst als einreichbar
  # gelten -- der naechste Submit wuerde sie doch noch anwenden.
  test 'eine verworfene Zeile ist in keinem der drei Scopes' do
    result(status: 'rejected')

    assert_empty @import.referee_course_results.submittable
    assert_empty @import.referee_course_results.deferred
    assert_empty @import.referee_course_results.open_for_importer
  end

  test 'awaiting_lv_review nimmt genau die eingereichten Zeilen' do
    wartet = result(status: 'pending_review', submitted: true)
    result(status: 'pending_review')
    result(status: 'pending_review', deferred: true)

    assert_equal [wartet.id], RefereeCourseResult.pending_review.awaiting_lv_review.ids
  end

  test 'awaiting_lv_review laesst die Zeilen eines abgebrochenen Imports draussen' do
    result(status: 'pending_review', submitted: true)
    @import.update!(status: 'cancelled')

    assert_empty RefereeCourseResult.pending_review.awaiting_lv_review
  end

  test 'close_if_done schliesst nur den teilweise eingereichten Import ohne offene Zeilen' do
    zeile = result(status: 'pending_review', deferred: true)
    @import.update!(status: 'partially_submitted')

    @import.close_if_done!
    assert_equal 'partially_submitted', @import.reload.status

    zeile.update!(status: 'rejected', deferred: false)
    @import.close_if_done!
    assert_equal 'submitted', @import.reload.status
  end

  test 'close_if_done laesst einen Entwurf in Ruhe' do
    result(status: 'rejected')

    @import.close_if_done!

    # Ein `in_review`-Import, dessen Zeilen alle verworfen sind, ist kein
    # eingereichter -- er gehoert abgebrochen, nicht abgeschlossen.
    assert_equal 'in_review', @import.reload.status
  end
end
