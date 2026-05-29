require 'test_helper'

class RefereeCourseSubmitPolicyTest < ActiveSupport::TestCase
  def make_result(match_type:)
    RefereeCourseResult.new(match_type: match_type, match_field_count: match_type == 'exact_match' ? 6 : 0)
  end

  test '6/6 exact_match überspringt Review IMMER (auch bei LV mit Kontrollprozess)' do
    sa = build(:state_association, referee_license_review_enabled: true)
    refute RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'exact_match'), sa)
  end

  test 'partial_match + LV mit Kontrollprozess → review_required' do
    sa = build(:state_association, referee_license_review_enabled: true)
    assert RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'partial_match'), sa)
  end

  test 'partial_match + LV ohne Kontrollprozess → kein Review' do
    sa = build(:state_association, referee_license_review_enabled: false)
    refute RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'partial_match'), sa)
  end

  test 'new_entry + LV mit Kontrollprozess → review_required' do
    sa = build(:state_association, referee_license_review_enabled: true)
    assert RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'new_entry'), sa)
  end

  test 'new_entry ohne LV (orphan/club nicht ableitbar) → review_required (safe default)' do
    assert RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'new_entry'), nil)
  end

  test 'partial_match ohne LV → review_required (safe default)' do
    assert RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'partial_match'), nil)
  end

  test 'Kind-LV erbt referee_license_review_enabled vom Parent' do
    parent = create(:state_association, referee_license_review_enabled: true)
    child = create(:state_association, parent: parent, referee_license_review_enabled: false)
    assert RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'partial_match'), child)
  end

  test 'Kind-LV ohne aktiven Parent-Flag erbt false (kein Review)' do
    parent = create(:state_association, referee_license_review_enabled: false)
    child = create(:state_association, parent: parent, referee_license_review_enabled: true)
    refute RefereeCourseSubmitPolicy.review_required?(make_result(match_type: 'partial_match'), child)
  end
end
