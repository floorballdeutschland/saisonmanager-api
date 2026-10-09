require 'test_helper'

# Paket 2: Selbstanmeldung im Schiri-Portal, Sammelanmeldung durch den Verein,
# Warteliste mit Nachruecken, Einwilligung der Erziehungsberechtigten.
class RefereeCourseRegistrationFlowsTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @club = create(:club, state_association: @lv)
    @l2 = RefereeLicenseLevel.create!(name: 'L2', validity_years: 1, position: 2)
    @course = RefereeCourse.create!(
      title: 'G-Kurs Kassel', course_type: 'g', state_association: @lv, status: 'published',
      license_level_ids: [@l2.id], max_participants: 1, contact_email: 'rsk@lv.example',
      cancellation_deadline: 10.days.from_now, registration_deadline: 20.days.from_now,
      sessions: [{ 'starts_at' => 30.days.from_now.iso8601, 'online_url' => 'https://zoom.example/geheim' }]
    )
    @field = @course.fields.create!(label: 'T-Shirt', field_type: 'select', options: %w[S M], required: true)
    @referee = create(:referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2000, 1, 1),
                                email: 'ada@example.org', club: @club, lizenznummer: 4711)
    @referee_user = create(:user, referee: @referee, email: 'ada@example.org',
                                  permissions: [{ 'user_group_id' => User::REFEREE_ROLE_ID }])
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def answers
    { @field.id.to_s => 'M' }
  end

  # --- Portal ----------------------------------------------------------------

  test 'Schiri sieht das Angebot ohne Online-Link und meldet sich an' do
    assert @referee_user.permissions_items[:menu_item_referee_courses_portal]
    login(@referee_user)
    get '/api/v2/referee/courses'
    assert_response :success
    offer = response.parsed_body['courses'].first
    assert_equal @course.id, offer['id']
    assert_nil offer['sessions'].first['online_url']
    assert_nil offer['registration_closed_reason']

    assert_enqueued_emails 1 do
      post "/api/v2/referee/courses/#{@course.id}/registration",
           params: { registration: { desired_license_level_id: @l2.id, custom_answers: answers } }, as: :json
    end
    assert_response :created
    reg = RefereeCourseRegistration.find(response.parsed_body['id'])
    assert_equal 'registered', reg.status
    assert_equal 'account', reg.identity_match
    assert_equal 'portal', reg.source
    assert_equal @club.id, reg.billing_club_id
  end

  test 'Portal verlangt Pflichtfelder' do
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration", params: { registration: {} }, as: :json
    assert_response :unprocessable_entity
    assert_match(/T-Shirt/, response.parsed_body['error'])
  end

  test 'nach dem Anmeldeschluss keine Anmeldung' do
    @course.update_columns(registration_deadline: 1.minute.ago)
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Anmeldeschluss/, response.parsed_body['error'])
  end

  test 'Mindestalter am ersten Kurstag' do
    @course.update!(min_age: 30)
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Mindestalter/, response.parsed_body['error'])
  end

  test 'Abmeldung im Portal und erneute Anmeldung' do
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    delete "/api/v2/referee/courses/#{@course.id}/registration"
    assert_response :success
    assert_equal 'cancelled_by_participant', response.parsed_body['status']
    assert_not response.parsed_body['late_cancellation']

    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    assert_response :created
  end

  test 'spaete Abmeldung wird markiert' do
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    @course.update_columns(cancellation_deadline: 1.minute.ago)
    delete "/api/v2/referee/courses/#{@course.id}/registration"
    assert response.parsed_body['late_cancellation']
  end

  test 'Konto ohne Schiri-Datensatz kommt nicht ins Portal' do
    login(@vm)
    get '/api/v2/referee/courses'
    assert_response :forbidden
  end

  # --- Warteliste --------------------------------------------------------------

  test 'voller Kurs: Warteliste, nach Abmeldung rueckt die aelteste nach' do
    first = @course.registrations.create!(vorname: 'Erst', nachname: 'X', geburtsdatum: Date.new(1990, 1, 1),
                                          status: 'registered', skip_required_answers: true)
    login(@referee_user)
    post "/api/v2/referee/courses/#{@course.id}/registration",
         params: { registration: { custom_answers: answers } }, as: :json
    assert_equal 'waitlisted', response.parsed_body['status']

    assert_enqueued_emails 1 do
      RefereeCourseRegistrar.new(@course).cancel(first)
    end
    assert_equal 'registered', @course.registrations.find_by(referee: @referee).status
  end

  test 'hoehere Hoechstzahl in der Verwaltung laesst nachruecken' do
    @course.registrations.create!(vorname: 'Erst', nachname: 'X', geburtsdatum: Date.new(1990, 1, 1),
                                  status: 'registered', skip_required_answers: true)
    waiting = @course.registrations.create!(vorname: 'Zweit', nachname: 'X', geburtsdatum: Date.new(1990, 1, 1),
                                            status: 'waitlisted', skip_required_answers: true)
    login(create(:user, :admin))
    patch "/api/v2/admin/referee_courses/#{@course.id}", params: { referee_course: { max_participants: 2 } },
                                                          as: :json
    assert_response :success
    assert_equal 'registered', waiting.reload.status
  end

  test 'Kursabsage benachrichtigt alle aktiven Anmeldungen' do
    @course.registrations.create!(vorname: 'A', nachname: 'X', geburtsdatum: Date.new(1990, 1, 1),
                                  email: 'a@example.org', status: 'registered', skip_required_answers: true)
    @course.registrations.create!(vorname: 'B', nachname: 'X', geburtsdatum: Date.new(1990, 1, 1),
                                  email: 'b@example.org', status: 'cancelled_by_participant',
                                  skip_required_answers: true)
    login(create(:user, :admin))
    assert_enqueued_emails 1 do
      patch "/api/v2/admin/referee_courses/#{@course.id}", params: { referee_course: { status: 'cancelled' } },
                                                            as: :json
    end
  end

  # --- Verein ------------------------------------------------------------------

  test 'Verein meldet eigenen Schiri an, fremden nicht' do
    assert @vm.permissions_items[:menu_item_club_referee_courses]
    foreign = create(:referee, club: create(:club, state_association: @lv))
    login(@vm)
    get '/api/v2/club/referee_courses/referees'
    assert_equal [@referee.id], response.parsed_body.pluck('id')

    post "/api/v2/club/referee_courses/#{@course.id}/registrations",
         params: { registration: { referee_id: foreign.id, custom_answers: answers } }, as: :json
    assert_response :not_found

    post "/api/v2/club/referee_courses/#{@course.id}/registrations",
         params: { registration: { referee_id: @referee.id, custom_answers: answers } }, as: :json
    assert_response :created
    assert_equal 'club', response.parsed_body['source']
    assert_equal 'confirmed_existing', RefereeCourseRegistration.last.identity_match

    get '/api/v2/club/referee_courses'
    assert_equal 1, response.parsed_body['registrations'].size
  end

  test 'Verein meldet neue Person unter 16 an: erst die Einwilligung plant ein' do
    @course.update!(max_participants: 5)
    login(@vm)
    person = { vorname: 'Kim', nachname: 'Klein', geburtsdatum: 12.years.ago.to_date.iso8601,
               custom_answers: answers }
    post "/api/v2/club/referee_courses/#{@course.id}/registrations", params: { registration: person }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Erziehungsberechtigten/, response.parsed_body['error'])

    assert_enqueued_emails 1 do
      post "/api/v2/club/referee_courses/#{@course.id}/registrations",
           params: { registration: person.merge(guardian_name: 'Eva Klein', guardian_email: 'eva@example.org') },
           as: :json
    end
    assert_response :created
    assert_equal 'pending_guardian', response.parsed_body['status']
    reg = RefereeCourseRegistration.find(response.parsed_body['id'])
    assert_equal 0, @course.registrations.seated.count

    # Token aus der eingereihten Mail ziehen
    job = enqueued_jobs.find { |j| j[:args].include?('guardian_consent') }
    token = job[:args].last['args'].last
    get "/api/v2/public/course_guardian_consents/#{token}"
    assert_response :success
    assert_equal 'Kim Klein', response.parsed_body['name']
    assert_nil response.parsed_body['course']['sessions'].first['online_url']
    assert_equal 'pending_guardian', reg.reload.status, 'GET darf nicht einwilligen'

    post "/api/v2/public/course_guardian_consents/#{token}"
    assert_response :success
    assert_equal 'registered', reg.reload.status
    assert reg.guardian_confirmed_at.present?

    post "/api/v2/public/course_guardian_consents/#{token}"
    assert_response :not_found
  end

  test 'Verein meldet nur fuer eigene Vereine an' do
    login(@vm)
    other = create(:club, state_association: @lv)
    post "/api/v2/club/referee_courses/#{@course.id}/registrations",
         params: { registration: { vorname: 'A', nachname: 'B', geburtsdatum: '1990-01-01', club_id: other.id,
                                   custom_answers: answers } }, as: :json
    assert_response :unprocessable_entity
  end

  test 'Schalter aus: weder Portal noch Verein' do
    @setting.update!(referee_course_processes: { 'courses_enabled' => false })
    assert_not @referee_user.permissions_items[:menu_item_referee_courses_portal]
    login(@vm)
    get '/api/v2/club/referee_courses'
    assert_response :forbidden
  end

  test 'Bestaetigungsmail enthaelt den Online-Link, die Abmeldefrist und Reply-To' do
    reg = @course.registrations.create!(vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2000, 1, 1),
                                        email: 'ada@example.org', status: 'registered', skip_required_answers: true)
    mail = RefereeCourseMailer.registered(reg)
    assert_equal ['ada@example.org'], mail.to
    assert_equal ['rsk@lv.example'], mail.reply_to
    assert_match 'zoom.example/geheim', mail.body.encoded
    assert_match 'Anmeldung bestätigt', mail.subject
  end
end
