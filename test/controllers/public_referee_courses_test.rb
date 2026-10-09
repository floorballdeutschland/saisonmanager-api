require 'test_helper'

# Paket 3: oeffentliche Kursseite und Anmeldung ohne Konto.
class PublicRefereeCoursesTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @other_lv = create(:state_association)
    @club = create(:club, state_association: @lv)
    @course = RefereeCourse.create!(
      title: 'G-Kurs Kassel', course_type: 'g', state_association: @lv, status: 'published',
      max_participants: 10, sessions: [{ 'starts_at' => 30.days.from_now.iso8601, 'online_url' => 'https://zoom.example/x' }]
    )
    @hidden = RefereeCourse.create!(title: 'Intern', course_type: 'g', state_association: @lv, status: 'published',
                                    public: false)
    @foreign = RefereeCourse.create!(title: 'Fremd', course_type: 'f', state_association: @other_lv,
                                     status: 'published', format: 'online')
  end

  def person(extra = {})
    { vorname: 'Neu', nachname: 'Ling', geburtsdatum: '2000-03-04', email: 'neu@example.org', club_id: @club.id,
      consent: true }.merge(extra)
  end

  # Raw-Token aus der eingereihten Mail (letztes Argument des Mailer-Aufrufs).
  def token_from_last_mail(action)
    job = enqueued_jobs.reverse.find { |j| j[:args].include?(action) }
    job[:args].last['args'].last
  end

  test 'Liste ohne Login, nur oeffentliche Kurse, ohne Online-Link, filterbar nach LV' do
    get '/api/v2/public/referee_courses'
    assert_response :success
    body = response.parsed_body
    assert body['enabled']
    assert_equal [@course.id, @foreign.id].sort, body['courses'].pluck('id').sort
    assert_nil body['courses'].find { |c| c['id'] == @course.id }['sessions'].first['online_url']

    get '/api/v2/public/referee_courses', params: { state_association_id: @lv.id }
    assert_equal [@course.id], response.parsed_body['courses'].pluck('id')
    get '/api/v2/public/referee_courses', params: { course_format: 'online' }
    assert_equal [@foreign.id], response.parsed_body['courses'].pluck('id')

    get "/api/v2/public/referee_courses/#{@hidden.id}"
    assert_response :not_found
  end

  test 'Vereinsauswahl ohne deaktivierte Vereine' do
    gone = create(:club, state_association: @lv, deactivated_at: 1.day.ago)
    get '/api/v2/public/referee_courses/clubs'
    assert_response :success
    ids = response.parsed_body.pluck('id')
    assert_includes ids, @club.id
    assert_not_includes ids, gone.id
  end

  test 'Schalter aus: Liste leer, Anmeldung nicht moeglich' do
    @setting.update!(referee_course_processes: { 'courses_enabled' => false })
    get '/api/v2/public/referee_courses'
    assert_equal false, response.parsed_body['enabled']
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    assert_response :not_found
  end

  test 'neue Person: erst die Bestaetigung plant ein, Abmeldelink in der Bestaetigung' do
    assert_enqueued_emails 1 do
      post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    end
    assert_response :created
    reg = RefereeCourseRegistration.last
    assert_equal 'pending_email', reg.status
    assert_equal 'public', reg.source
    assert_equal '2026-10', reg.consent_version
    assert reg.consent_ip.present?
    assert_equal 0, @course.registrations.seated.count

    token = token_from_last_mail('confirm_email')
    get "/api/v2/public/course_registrations/confirm/#{token}"
    assert_response :success
    assert_equal 'pending_email', reg.reload.status, 'GET darf nicht bestaetigen'

    assert_enqueued_emails 1 do
      post "/api/v2/public/course_registrations/confirm/#{token}"
    end
    assert_equal 'registered', reg.reload.status
    assert reg.cancel_token_digest.present?

    cancel_token = token_from_last_mail('registered')
    get "/api/v2/public/course_registrations/cancel/#{cancel_token}"
    assert_response :success
    post "/api/v2/public/course_registrations/cancel/#{cancel_token}"
    assert_response :success
    assert_equal 'cancelled_by_participant', reg.reload.status
  end

  test 'ohne Einwilligung keine Anmeldung' do
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: person(consent: false) }, as: :json
    assert_response :unprocessable_entity
  end

  test 'abgelaufener Bestaetigungslink' do
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    token = token_from_last_mail('confirm_email')
    RefereeCourseRegistration.last.update_columns(email_confirmation_expires_at: 1.minute.ago)
    post "/api/v2/public/course_registrations/confirm/#{token}"
    assert_response :not_found
  end

  test 'Bestandsschiri per Lizenznummer: Link an die hinterlegte Adresse, nicht an die eingegebene' do
    referee = create(:referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(1999, 5, 6),
                               email: 'ada@hinterlegt.example', lizenznummer: 4711, club: @club)
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: person(lizenznummer: '4711', geburtsdatum: '1999-05-06',
                                        email: 'angreifer@example.org') }, as: :json
    assert_response :created
    reg = RefereeCourseRegistration.last
    assert_equal referee.id, reg.referee_id
    assert_equal 'ada@hinterlegt.example', reg.email
    assert_equal 'Ada', reg.vorname
    assert_equal 'confirmed_existing', reg.identity_match

    mail = RefereeCourseMailer.confirm_email(reg, 'x')
    assert_equal ['ada@hinterlegt.example'], mail.to
  end

  test 'falsches Geburtsdatum zur Lizenznummer: neue Person mit Hinweis, gleiche Antwort' do
    referee = create(:referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(1999, 5, 6),
                               email: 'ada@hinterlegt.example', lizenznummer: 4711)
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: person(vorname: 'Ada', nachname: 'Muster', lizenznummer: '4711',
                                        geburtsdatum: '1999-05-07', email: 'ada@neu.example') }, as: :json
    assert_response :created
    assert_equal({ 'status' => 'pending_email' }, response.parsed_body)
    reg = RefereeCourseRegistration.last
    assert_nil reg.referee_id
    assert_equal 'needs_review', reg.identity_match
    assert_equal [referee.id], reg.match_candidates.pluck('id')
  end

  test 'Zwilling wird nicht als Kandidat vorgeschlagen' do
    create(:referee, vorname: 'Luke', nachname: 'Stephan', geburtsdatum: Date.new(2005, 1, 30))
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: person(vorname: 'Niclas', nachname: 'Stephan', geburtsdatum: '2005-01-30') },
         as: :json
    assert_equal 'new_person', RefereeCourseRegistration.last.identity_match
  end

  test 'unter 16: erst E-Mail, dann Einwilligung der Erziehungsberechtigten' do
    young = person(vorname: 'Kim', geburtsdatum: 12.years.ago.to_date.iso8601)
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: young }, as: :json
    assert_response :unprocessable_entity

    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: young.merge(guardian_name: 'Eva', guardian_email: 'eva@example.org') }, as: :json
    assert_response :created
    token = token_from_last_mail('confirm_email')
    assert_enqueued_emails 1 do
      post "/api/v2/public/course_registrations/confirm/#{token}"
    end
    reg = RefereeCourseRegistration.last
    assert_equal 'pending_guardian', reg.status
    assert reg.email_confirmed_at.present?

    guardian_token = token_from_last_mail('guardian_consent')
    post "/api/v2/public/course_guardian_consents/#{guardian_token}"
    assert_equal 'registered', reg.reload.status
  end

  test 'RSK bestaetigt einen Hinweis-Fall als neue Person' do
    reg = @course.registrations.create!(vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1),
                                        identity_match: 'needs_review', skip_required_answers: true)
    login_admin
    patch "/api/v2/admin/referee_courses/#{@course.id}/registrations/#{reg.id}",
          params: { registration: { identity_match: 'new_person' } }, as: :json
    assert_response :success
    assert_equal 'new_person', reg.reload.identity_match
  end

  test 'Loeschfrist: alte Anmeldungen ohne Schiri und nie bestaetigte fallen weg' do
    old_course = RefereeCourse.create!(title: 'Alt', course_type: 'g', state_association: @lv,
                                       sessions: [{ 'starts_at' => 14.months.ago.iso8601 }])
    gone = old_course.registrations.create!(vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1),
                                            skip_required_answers: true)
    kept_referee = old_course.registrations.create!(vorname: 'C', nachname: 'D', geburtsdatum: Date.new(2000, 1, 1),
                                                    referee: create(:referee), skip_required_answers: true)
    unconfirmed = @course.registrations.create!(vorname: 'E', nachname: 'F', geburtsdatum: Date.new(2000, 1, 1),
                                                status: 'pending_email', email_confirmation_expires_at: 10.days.ago,
                                                skip_required_answers: true)
    fresh = @course.registrations.create!(vorname: 'G', nachname: 'H', geburtsdatum: Date.new(2000, 1, 1),
                                          skip_required_answers: true)

    ids = RefereeCourseRegistrationPurge.scopes.values.flat_map { |s| s.pluck(:id) }
    assert_equal [gone.id, unconfirmed.id].sort, ids.sort
    assert_not_includes ids, kept_referee.id
    assert_not_includes ids, fresh.id
  end

  test 'Lizenznummer-Probe ohne Pflichtangaben verraet nichts' do
    create(:referee, geburtsdatum: Date.new(1999, 5, 6), email: 'ada@hinterlegt.example', lizenznummer: 4711)
    probe = lambda do |datum|
      post "/api/v2/public/referee_courses/#{@course.id}/registrations",
           params: { registration: { lizenznummer: '4711', geburtsdatum: datum, consent: true } }, as: :json
      [response.status, response.parsed_body]
    end
    assert_equal probe.call('1999-05-06'), probe.call('1999-05-07')
    assert_equal 0, RefereeCourseRegistration.count
  end

  test 'bereits angemeldeter Schiri: gleiche Antwort, keine neue Zeile, keine Mail' do
    referee = create(:referee, vorname: 'Ada', nachname: 'M', geburtsdatum: Date.new(1999, 5, 6),
                               email: 'ada@hinterlegt.example', lizenznummer: 4711)
    @course.registrations.create!(referee: referee, vorname: 'Ada', nachname: 'M', geburtsdatum: referee.geburtsdatum,
                                  status: 'registered', skip_required_answers: true)
    assert_no_enqueued_emails do
      post "/api/v2/public/referee_courses/#{@course.id}/registrations",
           params: { registration: person(lizenznummer: '4711', geburtsdatum: '1999-05-06') }, as: :json
    end
    assert_response :created
    assert_equal 1, @course.registrations.count
  end

  test 'nie bestaetigte Anmeldung sperrt nicht: erneut anmelden ersetzt sie, Portal geht auch' do
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    assert_response :created
    assert_equal 1, @course.registrations.where(status: 'pending_email').count

    referee = create(:referee, vorname: 'Ada', nachname: 'M', geburtsdatum: Date.new(1999, 5, 6),
                               email: 'ada@hinterlegt.example', lizenznummer: 4711)
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: person(lizenznummer: '4711', geburtsdatum: '1999-05-06') }, as: :json
    stale_token = token_from_last_mail('confirm_email')
    portal = @course.registrations.create!(referee: referee, vorname: 'Ada', nachname: 'M',
                                           geburtsdatum: referee.geburtsdatum, status: 'registered',
                                           source: 'portal', skip_required_answers: true)
    assert portal.persisted?

    post "/api/v2/public/course_registrations/confirm/#{stale_token}"
    assert_response :not_found
    assert_equal 1, @course.registrations.where(referee: referee).count
  end

  test 'Bestaetigungslink nach Kursabsage ist ungueltig' do
    post "/api/v2/public/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    token = token_from_last_mail('confirm_email')
    @course.update_columns(status: 'cancelled')
    get "/api/v2/public/course_registrations/confirm/#{token}"
    assert_response :not_found
    post "/api/v2/public/course_registrations/confirm/#{token}"
    assert_response :not_found
  end

  private

  def login_admin
    admin = create(:user, :admin)
    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success
  end
end
