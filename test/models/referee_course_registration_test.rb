require 'test_helper'

class RefereeCourseRegistrationTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @l1 = RefereeLicenseLevel.create!(name: 'L1', validity_years: 1, position: 1)
    @l2 = RefereeLicenseLevel.create!(name: 'L2', validity_years: 1, position: 2)
    @j1 = RefereeLicenseLevel.create!(name: 'J1', validity_years: 1, position: 5)
    @lv = create(:state_association)
    @course = RefereeCourse.create!(title: 'F-Kurs', course_type: 'f', state_association: @lv,
                                    license_level_ids: [@l2.id, @l1.id],
                                    fee_member_cents: 2500, fee_non_member_cents: 3000,
                                    sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00' }])
    @tshirt = @course.fields.create!(label: 'T-Shirt', field_type: 'select', options: %w[S M L], required: true)
    @news = @course.fields.create!(label: 'Newsletter', field_type: 'checkbox')
  end

  def build(**attrs)
    @course.registrations.new({ vorname: 'Niclas', nachname: 'Stephan', geburtsdatum: Date.new(2005, 1, 30),
                                email: 'eltern@example.org',
                                custom_answers: { @tshirt.id.to_s => 'M' } }.merge(attrs))
  end

  test 'Zwillinge mit gleicher Adresse und gleichem Geburtsdatum duerfen sich beide anmelden' do
    build.save!
    assert build(vorname: 'Luke').save
    dup = build(email: 'ELTERN@example.org')
    assert_not dup.save
    assert_match(/bereits angemeldet/, dup.errors.full_messages.join)
  end

  test 'Pflichtfeld fehlt' do
    r = build(custom_answers: {})
    assert_not r.valid?
    assert_match(/T-Shirt/, r.errors.full_messages.join)
  end

  test 'Verwaltung darf Pflichtfelder leer lassen' do
    r = build(custom_answers: {}, skip_required_answers: true)
    assert r.valid?, r.errors.full_messages.join
  end

  test 'Auswahl ausserhalb der Optionen und unbekannte Felder' do
    r = build(custom_answers: { @tshirt.id.to_s => 'XXL', '999999' => 'x' })
    assert_not r.valid?
    assert_match(/Auswahlmöglichkeiten/, r.errors.full_messages.join)
    assert_not r.custom_answers.key?('999999')
  end

  test 'Checkbox muss ein Wahrheitswert sein' do
    r = build(custom_answers: { @tshirt.id.to_s => 'M', @news.id.to_s => 'ja' })
    assert_not r.valid?
  end

  test 'angestrebte Lizenzstufe muss zum Kurs gehoeren' do
    assert build(desired_license_level_id: @l1.id).valid?
    r = build(desired_license_level_id: @j1.id)
    assert_not r.valid?
    assert r.errors.key?(:desired_license_level_id)
  end

  test 'kostenuebernehmender Verein ist vorgegeben der eigene' do
    club = create(:club, state_association: @lv)
    r = build(club: club)
    r.save!
    assert_equal club.id, r.billing_club_id
  end

  test 'Rechnungsanschrift nur ohne Verein' do
    club = create(:club, state_association: @lv)
    assert_not build(club: club, billing_address: 'Weg 1').valid?
    assert build(billing_address: 'Weg 1').valid?
  end

  test 'Mitgliedspreis nur fuer Vereine des Kurs-LV' do
    own = create(:club, state_association: @lv)
    foreign = create(:club, state_association: create(:state_association))
    assert_equal 2500, build(club: own).fee_cents
    assert_equal 3000, build(club: foreign).fee_cents
    assert_equal 3000, build.fee_cents
  end

  test 'Felddefinition ist mit Anmeldungen gesperrt, Text bleibt aenderbar' do
    build.save!
    assert_not @tshirt.reload.update(options: %w[S M])
    assert @tshirt.reload.update(label: 'T-Shirt-Größe')
  end

  test 'spaete Abmeldung' do
    @course.update!(cancellation_deadline: Time.zone.parse('2026-11-14 23:59'))
    r = build
    r.save!
    r.update!(status: 'cancelled_by_participant', cancelled_at: Time.zone.parse('2026-11-18 10:00'))
    assert r.late_cancellation?
  end

  test 'Alter am ersten Kurstag' do
    assert_equal 21, build.age_at_course
    assert_equal 21, build(geburtsdatum: Date.new(2005, 11, 21)).age_at_course
    assert_equal 20, build(geburtsdatum: Date.new(2005, 11, 22)).age_at_course
  end
end
