require 'test_helper'

# Paket 4: Die RSK reicht einen Kurs ein, FD erteilt jede Lizenz einzeln.
class RefereeCourseLicensingTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @club = create(:club, state_association: @lv)
    @l2 = RefereeLicenseLevel.create!(name: 'L2', validity_years: 1, position: 2)
    @l3 = RefereeLicenseLevel.create!(name: 'L3', validity_years: 2, position: 3)
    @rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
    @fd = create(:user, permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 0 }])
    @course = RefereeCourse.create!(
      title: 'G-Kurs Kassel', course_type: 'g', state_association: @lv, status: 'held',
      license_level_ids: [@l3.id],
      sessions: [{ 'starts_at' => '2026-11-21T09:00:00+01:00' }]
    )
    @referee = create(:referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2000, 1, 1),
                                email: 'ada@example.org', lizenznummer: 4711, club: @club, lizenzstufe: nil,
                                gueltigkeit: nil)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def reg(attrs)
    @course.registrations.create!({ vorname: 'X', nachname: 'Y', geburtsdatum: Date.new(2001, 2, 3),
                                    skip_required_answers: true }.merge(attrs))
  end

  def ready_course
    reg(referee: @referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: @referee.geburtsdatum,
        email: 'alt@example.org', status: 'attended', result: 'passed', points: 30,
        identity_match: 'confirmed_existing', desired_license_level: @l3)
    reg(vorname: 'Neu', nachname: 'Ling', email: 'neu@example.org', club: @club, status: 'attended',
        result: 'passed', identity_match: 'new_person')
    reg(vorname: 'Durch', nachname: 'Gefallen', status: 'attended', result: 'failed')
    reg(vorname: 'Nicht', nachname: 'Da', status: 'no_show')
  end

  test 'Einreichen nennt fehlende Anwesenheit, Ergebnisse und Zuordnungen' do
    reg(vorname: 'Offen', status: 'registered')
    reg(vorname: 'Ohne', status: 'attended')
    reg(vorname: 'Unklar', status: 'attended', result: 'passed', identity_match: 'needs_review')
    login(@rsk)
    post "/api/v2/admin/referee_courses/#{@course.id}/submit_results"
    assert_response :unprocessable_entity
    problems = response.parsed_body['problems'].join(' ')
    assert_match(/Anwesenheit fehlt bei: Offen/, problems)
    assert_match(/Ergebnis fehlt bei: Ohne/, problems)
    assert_match(/Zuordnung ungeklärt bei: Unklar/, problems)
    assert_equal 'held', @course.reload.status
  end

  test 'Einreichen erzeugt Zeilen nur fuer Bestandene, ohne Lizenzstufe, und sperrt den Kurs' do
    ready_course
    login(@rsk)
    post "/api/v2/admin/referee_courses/#{@course.id}/submit_results"
    assert_response :success
    assert_equal 2, response.parsed_body['submitted_results']
    assert_equal 'results_submitted', @course.reload.status

    results = RefereeCourseResult.where(referee_course: @course).order(:id)
    assert_equal 2, results.size
    assert(results.all? { |r| r.lizenzstufe.nil? && r.status == 'pending_review' })
    existing = results.find_by(referee: @referee)
    assert_equal 'ada@example.org', existing.master_email_final, 'Stammdaten vom Schiri, nicht aus der Anmeldung'
    assert_equal 'G', existing.course_data.dig('kurs_1', 'stufe')

    patch "/api/v2/admin/referee_courses/#{@course.id}", params: { referee_course: { title: 'x' } }, as: :json
    assert_response :unprocessable_entity
  end

  test 'Status results_submitted laesst sich nicht von Hand setzen' do
    login(@rsk)
    patch "/api/v2/admin/referee_courses/#{@course.id}", params: { referee_course: { status: 'results_submitted' } },
                                                          as: :json
    assert_response :unprocessable_entity
  end

  test 'LV-RSK kann keine Lizenzstufe setzen' do
    r = reg(status: 'attended', result: 'passed')
    login(@rsk)
    patch "/api/v2/admin/referee_courses/#{@course.id}/registrations/#{r.id}",
          params: { registration: { awarded_license_level_id: @l3.id } }, as: :json
    assert_nil r.reload.awarded_license_level_id

    get '/api/v2/admin/referee_course_licensing'
    assert_response :forbidden
  end

  test 'FD erteilt: Bestandsschiri bekommt Lizenz und Mail, neue Person Lizenznummer und Konto' do
    ready_course
    RefereeCourseSubmission.new(@course, submitted_by: @rsk).call
    login(@fd)
    get '/api/v2/admin/referee_course_licensing'
    assert_response :success
    rows = response.parsed_body
    assert_equal 2, rows.size
    existing_row = rows.find { |r| r.dig('referee', 'id') == @referee.id }
    assert_equal 'L3', existing_row.dig('registration', 'desired_level')
    new_row = rows.find { |r| r['referee'].nil? }

    post "/api/v2/admin/referee_course_licensing/#{existing_row['id']}/approve"
    assert_response :unprocessable_entity
    assert_match(/Lizenzstufe/, response.parsed_body['error'])

    patch "/api/v2/admin/referee_course_licensing/#{existing_row['id']}",
          params: { licensing: { lizenzstufe: 'L3' } }, as: :json
    assert_response :success
    assert_equal Date.new(2028, 9, 30), Date.parse(response.parsed_body['gueltigkeit'])

    post "/api/v2/admin/referee_course_licensing/#{existing_row['id']}/approve"
    assert_response :success
    assert_equal 'L3', @referee.reload.lizenzstufe
    assert_equal @l3.id, @course.registrations.find_by(referee: @referee).awarded_license_level_id

    patch "/api/v2/admin/referee_course_licensing/#{new_row['id']}",
          params: { licensing: { lizenzstufe: 'L2' } }, as: :json
    post '/api/v2/admin/referee_course_licensing/approve_many', params: { ids: [new_row['id']] }, as: :json
    assert_response :success
    assert response.parsed_body['results'].first['ok'], response.body
    created = Referee.find_by(vorname: 'Neu', nachname: 'Ling')
    assert created.lizenznummer.present?
    assert_equal 'L2', created.lizenzstufe
    assert created.user.present?, 'neue Person mit Adresse bekommt ein Konto'
    assert_equal created.id, @course.registrations.find_by(vorname: 'Neu').referee_id

    get "/api/v2/admin/referees/#{created.id}/courses"
    assert_response :success
    assert_equal 'G-Kurs Kassel', response.parsed_body.first['course_title']
  end

  test 'FD ordnet einen anderen Schiri zu oder lehnt mit Grund ab' do
    reg(vorname: 'Neu', nachname: 'Ling', status: 'attended', result: 'passed')
    RefereeCourseSubmission.new(@course, submitted_by: @rsk).call
    row = RefereeCourseResult.last
    login(@fd)
    patch "/api/v2/admin/referee_course_licensing/#{row.id}",
          params: { licensing: { referee_id: @referee.id } }, as: :json
    assert_response :success
    assert_equal @referee.id, row.reload.referee_id
    assert_equal 'ada@example.org', row.master_email_final

    post "/api/v2/admin/referee_course_licensing/#{row.id}/reject", params: { rejection_reason: '' }, as: :json
    assert_response :unprocessable_entity
    post "/api/v2/admin/referee_course_licensing/#{row.id}/reject",
         params: { rejection_reason: 'G-Kurs bereits 2022 absolviert' }, as: :json
    assert_response :success
    assert_equal 'rejected', row.reload.status

    login(@rsk)
    get "/api/v2/admin/referee_courses/#{@course.id}/registrations"
    license = response.parsed_body.first['license']
    assert_equal 'rejected', license['status']
    assert_equal 'G-Kurs bereits 2022 absolviert', license['rejection_reason']
  end

  test 'CSV-Freigabeliste der LV zeigt keine Kurszeilen' do
    ready_course
    RefereeCourseSubmission.new(@course, submitted_by: @rsk).call
    login(@fd)
    get '/api/v2/admin/referee_course_results'
    assert_response :success
    assert_empty response.parsed_body
  end

  test 'Menuepunkt Lizenzvergabe nur fuer FD' do
    assert @fd.permissions_items[:menu_item_referee_course_licensing]
    assert_not @rsk.permissions_items[:menu_item_referee_course_licensing]
  end
end
