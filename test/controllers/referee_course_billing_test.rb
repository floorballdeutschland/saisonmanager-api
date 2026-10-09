require 'test_helper'
require 'csv'

# Paket 5: Rechnungsexport je Landesverband und Teilnehmerliste je Kurs.
class RefereeCourseBillingTest < ActionDispatch::IntegrationTest
  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @other_go = create(:game_operation)
    @club = create(:club, state_association: @lv, name: 'TVK', long_name: 'TV Kassel e.V.', street: 'Hallenweg',
                          house_number: '3', postcode: '34117', city: 'Kassel', contact_email: 'kasse@tvk.example')
    @bare_club = create(:club, state_association: @lv, name: 'Ohne', street: nil, contact_email: nil)
    @foreign_club = create(:club, state_association: @other_go.state_association, name: 'Fremd')
    @rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
    @other_rsk = create(:user, :rsk_scoped, game_operation_id: @other_go.id)
    @fd = create(:user, permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 0 }])
    @course = RefereeCourse.create!(
      title: 'G-Kurs Kassel', course_type: 'g', state_association: @lv, status: 'held',
      fee_member_cents: 2500, fee_non_member_cents: 5000, no_show_billable: false,
      cancellation_deadline: Time.zone.parse('2026-11-14 23:59'),
      sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00' }]
    )
    @tshirt = @course.fields.create!(label: 'Rechnungsvermerk', field_type: 'text', include_in_billing_export: true)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def reg(attrs)
    @course.registrations.create!({ vorname: 'X', nachname: 'Y', geburtsdatum: Date.new(2001, 2, 3),
                                    skip_required_answers: true }.merge(attrs))
  end

  def parse(raw)
    csv_text = raw.dup.force_encoding('UTF-8')
    assert csv_text.start_with?("\uFEFF"), 'BOM fuer Excel'
    CSV.parse(csv_text.delete_prefix("\uFEFF"), col_sep: ';', headers: true)
  end

  test 'Export: eine Zeile je abzurechnender Teilnahme, Vereinsanschrift, Mitgliedspreis' do
    reg(vorname: 'Ada', nachname: 'Muster', club: @club, status: 'attended',
        custom_answers: { @tshirt.id.to_s => 'Kostenstelle 7' })
    reg(vorname: 'Fremd', club: @foreign_club, status: 'attended')
    reg(vorname: 'Weg', club: @club, status: 'no_show')
    reg(vorname: 'Spaet', club: @club, status: 'cancelled_by_participant', held_seat_at_cancel: true,
        cancelled_at: Time.zone.parse('2026-11-18 10:00'))
    reg(vorname: 'Warteliste', club: @club, status: 'cancelled_by_participant', held_seat_at_cancel: false,
        cancelled_at: Time.zone.parse('2026-11-18 10:00'))
    reg(vorname: 'Rausgeworfen', club: @club, status: 'cancelled_by_organizer', held_seat_at_cancel: true,
        cancelled_at: Time.zone.parse('2026-11-18 10:00'))
    reg(vorname: 'Frueh', club: @club, status: 'cancelled_by_participant',
        cancelled_at: Time.zone.parse('2026-11-01 10:00'))
    reg(vorname: 'Privat', billing_address: 'Weg 1, 12345 Ort', status: 'attended')

    login(@rsk)
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: @lv.id }
    assert_response :success
    body = response.parsed_body
    names = body['rows'].map { |r| r['values'][0] }
    assert_equal %w[Ada Fremd Privat Spaet].sort, names.sort
    assert_equal 2500 + 5000 + 5000 + 2500, body['total_cents']

    post '/api/v2/admin/referee_course_billing_exports', params: { state_association_id: @lv.id }, as: :json
    assert_response :created
    export_id = response.parsed_body['id']

    get "/api/v2/admin/referee_course_billing_exports/#{export_id}/download"
    assert_response :success
    rows = parse(response.body)
    ada = rows.find { |r| r['Vorname'] == 'Ada' }
    assert_equal '21.11.2026', ada['Kursdatum']
    assert_equal 'G-Kurs', ada['Kurstyp']
    assert_equal 'TV Kassel e.V.', ada['Rechnungsempfänger']
    assert_equal 'Hallenweg 3', ada['Vereinsanschrift Straße']
    assert_equal 'kasse@tvk.example', ada['Vereins-Kontakt-E-Mail']
    assert_equal '25,00', ada['Betrag']
    assert_equal 'Kostenstelle 7', ada['Rechnungsvermerk']
    assert_equal 'spät abgemeldet', rows.find { |r| r['Vorname'] == 'Spaet' }['Teilnahme']
    assert_equal 'Weg 1, 12345 Ort', rows.find { |r| r['Vorname'] == 'Privat' }['Rechnungsanschrift (ohne Verein)']

    # Zweiter Export: nichts doppelt
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: @lv.id }
    assert_equal 0, response.parsed_body['row_count']
    get '/api/v2/admin/referee_course_billing_exports/preview',
        params: { state_association_id: @lv.id, include_billed: true }
    assert_equal 4, response.parsed_body['row_count']
  end

  test 'kein zweiter Export ueber include_billed, kein Export ueber veraltete Vorschau' do
    reg(vorname: 'Ada', club: @club, status: 'attended')
    login(@rsk)
    post '/api/v2/admin/referee_course_billing_exports', params: { state_association_id: @lv.id }, as: :json
    assert_response :created
    post '/api/v2/admin/referee_course_billing_exports',
         params: { state_association_id: @lv.id, include_billed: true }, as: :json
    assert_response :unprocessable_entity
    assert_equal 1, RefereeCourseBillingExport.count

    stale = RefereeCourseBilling.new(state_association_id: @lv.id)
    reg(vorname: 'Bo', club: @club, status: 'attended')
    stale.rows
    RefereeCourseBilling.new(state_association_id: @lv.id).create!(user: @rsk)
    assert_raises(RefereeCourseBilling::StaleRows) { stale.create!(user: @rsk) }
  end

  test 'Formeln aus Namen werden in der CSV entschaerft' do
    reg(vorname: '=HYPERLINK("https://evil.example";"x")', nachname: '+1', club: @club, status: 'attended')
    csv = RefereeCourseBilling.new(state_association_id: @lv.id).to_csv
    row = parse(csv).first
    assert row['Vorname'].start_with?("'=")
    assert_equal "'+1", row['Name']
    assert_equal '25,00', row['Betrag']
    participants = parse(RefereeCourseParticipantList.new(@course).to_csv).first
    assert participants['Vorname'].start_with?("'=")
  end

  test 'Warnung bei fehlender Vereinsanschrift' do
    reg(club: @bare_club, status: 'attended')
    login(@rsk)
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: @lv.id }
    warnings = response.parsed_body['rows'].first['warnings']
    assert_includes warnings, 'Vereinsanschrift unvollständig'
    assert_includes warnings, 'Verein ohne Kontakt-E-Mail'
  end

  test 'Gebuehr nur bei Lizenz: erst nach erteilter Lizenz abrechenbar' do
    @course.update!(fee_only_on_license: true)
    r = reg(vorname: 'Ada', club: @club, status: 'attended', result: 'passed')
    billing = RefereeCourseBilling.new(state_association_id: @lv.id)
    assert_empty billing.rows
    assert_equal [r.id], billing.waiting_for_license.map(&:id)

    @course.update_columns(status: 'results_submitted')
    RefereeCourseResult.create!(referee_course: @course, referee_course_registration: r, status: 'applied',
                                match_type: 'new_entry', match_field_count: 0, lizenzstufe: 'L3')
    assert_equal 1, RefereeCourseBilling.new(state_association_id: @lv.id).rows.size
  end

  test 'Nichterscheinen nur, wenn der Kurs es berechnet; abgesagte Kurse nie' do
    reg(club: @club, status: 'no_show')
    @course.update!(no_show_billable: true)
    assert_equal 1, RefereeCourseBilling.new(state_association_id: @lv.id).rows.size
    @course.update_columns(status: 'cancelled')
    assert_equal 0, RefereeCourseBilling.new(state_association_id: @lv.id).rows.size
  end

  test 'Bundesweiter Kurs mit Rechnung an den LV' do
    national = RefereeCourse.create!(title: 'N-Kurs', course_type: 'n', status: 'held', fee_member_cents: 16_000,
                                     bill_state_association: true,
                                     sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00' }])
    national.registrations.create!(vorname: 'Ada', nachname: 'M', geburtsdatum: Date.new(1990, 1, 1), club: @club,
                                   status: 'attended', skip_required_answers: true)
    billing = RefereeCourseBilling.new(state_association_id: nil)
    assert_equal @lv.name, billing.rows.first.recipient

    login(@rsk)
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: 'national' }
    assert_response :forbidden
    login(@fd)
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: 'national' }
    assert_response :success
  end

  test 'fremder LV: kein Export und kein Download' do
    reg(club: @club, status: 'attended')
    export = RefereeCourseBilling.new(state_association_id: @lv.id).create!(user: @rsk)
    login(@other_rsk)
    get '/api/v2/admin/referee_course_billing_exports/preview', params: { state_association_id: @lv.id }
    assert_response :forbidden
    get "/api/v2/admin/referee_course_billing_exports/#{export.id}/download"
    assert_response :forbidden
    get '/api/v2/admin/referee_course_billing_exports'
    assert_empty response.parsed_body
  end

  test 'Teilnehmerliste mit Kontaktdaten und Zusatzfeldern' do
    reg(vorname: 'Ada', nachname: 'Muster', email: 'ada@example.org', club: @club, status: 'registered',
        custom_answers: { @tshirt.id.to_s => 'Notiz' })
    login(@rsk)
    get "/api/v2/admin/referee_courses/#{@course.id}/participants"
    assert_response :success
    row = parse(response.body).first
    assert_equal 'ada@example.org', row['E-Mail']
    assert_equal 'angemeldet', row['Status']
    assert_equal 'Notiz', row['Rechnungsvermerk']

    login(@other_rsk)
    get "/api/v2/admin/referee_courses/#{@course.id}/participants"
    assert_response :forbidden
  end
end
