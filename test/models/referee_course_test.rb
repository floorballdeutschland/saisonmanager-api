require 'test_helper'

class RefereeCourseTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @l1 = RefereeLicenseLevel.create!(name: 'L1', validity_years: 1, position: 1)
    @l2 = RefereeLicenseLevel.create!(name: 'L2', validity_years: 1, position: 2)
    @lv = create(:state_association)
  end

  def course(**attrs)
    RefereeCourse.create!({ title: 'F-Kurs', course_type: 'f', state_association: @lv,
                            license_level_ids: [@l2.id, @l1.id] }.merge(attrs))
  end

  test 'Kurstage kommen aus den Terminen, gerechnet in deutscher Zeit' do
    # 23:30 UTC am 14.11. ist in Berlin schon der 15.11.
    c = course(sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00', 'ends_at' => '2026-11-21T17:00:00+01:00' },
                          { 'starts_at' => '2026-11-14T23:30:00Z', 'format' => 'online' }])
    assert_equal Date.new(2026, 11, 15), c.starts_on
    assert_equal Date.new(2026, 11, 21), c.ends_on
  end

  test 'Termin mit Ende vor Beginn ist ungueltig' do
    c = RefereeCourse.new(title: 'x', course_type: 'g',
                          sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00',
                                       'ends_at' => '2026-11-21T08:00:00+01:00' }])
    assert_not c.valid?
    assert_match(/Ende liegt vor dem Beginn/, c.errors.full_messages.join)
  end

  test 'Statuswechsel nur entlang der erlaubten Uebergaenge' do
    c = course
    c.status = 'results_submitted'
    assert_not c.valid?
    c.status = 'published'
    assert c.valid?
  end

  test 'Mindestzahl groesser Hoechstzahl ist ungueltig' do
    c = RefereeCourse.new(title: 'x', course_type: 'g', min_participants: 10, max_participants: 5)
    assert_not c.valid?
    assert c.errors.key?(:min_participants)
  end

  test 'Rechnung an den LV gibt es nur bundesweit' do
    c = RefereeCourse.new(title: 'x', course_type: 'n', state_association: @lv, bill_state_association: true)
    assert_not c.valid?
    c.state_association = nil
    assert c.valid?
  end

  test 'unbekannte Lizenzstufe wird abgelehnt' do
    c = RefereeCourse.new(title: 'x', course_type: 'g', license_level_ids: [999_999])
    assert_not c.valid?
    assert c.errors.key?(:license_level_ids)
  end

  test 'eigener LV faellt aus der Partnerliste' do
    other = create(:state_association)
    c = course(partner_state_association_ids: [@lv.id, other.id, ''])
    assert_equal [other.id], c.partner_state_association_ids
    assert_equal [@lv.id, other.id], c.managing_state_association_ids
  end

  test 'freie Plaetze zaehlen nur Plaetze haltende Anmeldungen' do
    c = course(max_participants: 2)
    reg = { vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1) }
    c.registrations.create!(reg.merge(status: 'registered'))
    c.registrations.create!(reg.merge(vorname: 'C', status: 'waitlisted'))
    c.registrations.create!(reg.merge(vorname: 'D', status: 'cancelled_by_participant'))
    assert_equal 1, c.free_seats
  end

  test 'Prozess-Schalter gilt je beteiligtem LV' do
    other = create(:state_association)
    c = course(partner_state_association_ids: [other.id])
    assert_not c.process_enabled?

    Setting.first.update!(referee_course_processes: { 'courses_enabled' => true,
                                                      'courses_state_association_ids' => [other.id] })
    assert c.reload.process_enabled?
    assert_not course(title: 'nur LV').process_enabled?
  end
end
