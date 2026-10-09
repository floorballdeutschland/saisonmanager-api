require 'test_helper'

# Kursleitung (Paket 1b): Zuordnung durch die RSK, Rolle 8 am Konto und die
# Ansicht „Meine Kurse".
class RefereeCourseLeadsTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
    @course = RefereeCourse.create!(title: 'G-Kurs Kassel', course_type: 'g', state_association: @lv,
                                    contact_email: 'rsk@lv.example')
    @field_visible = @course.fields.create!(label: 'Erfahrung', field_type: 'text')
    @field_hidden = @course.fields.create!(label: 'Rechnungsvermerk', field_type: 'text', visible_to_lead: false)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def lead_role?(user)
    user.reload.permissions.any? { |p| p['user_group_id'].to_i == User::COURSE_LEAD_ROLE_ID }
  end

  test 'neue Person wird als kl-nachname angelegt und eingeladen' do
    login(@rsk)
    assert_enqueued_emails 1 do
      post "/api/v2/admin/referee_courses/#{@course.id}/leads",
           params: { lead: { first_name: 'Jörg', last_name: 'Müller', email: 'Joerg@Example.org' } }, as: :json
    end
    assert_response :created
    assert response.parsed_body['invited']
    user = User.find(response.parsed_body['user_id'])
    assert_equal 'kl-mueller', user.user_name
    assert_equal 'joerg@example.org', user.email
    assert lead_role?(user)
    assert user.password_reset_token.present?
  end

  test 'Schiri mit Konto bekommt die Rolle zusaetzlich, ohne Einladung' do
    referee = create(:referee, email: 'sr@example.org')
    user = create(:user, referee: referee, permissions: [{ 'user_group_id' => User::REFEREE_ROLE_ID }])
    login(@rsk)
    assert_no_enqueued_emails do
      post "/api/v2/admin/referee_courses/#{@course.id}/leads", params: { lead: { referee_id: referee.id } }, as: :json
    end
    assert_response :created
    assert lead_role?(user)
    assert user.reload.valid?, 'Schiri-Rolle und Kursleitung muessen kombinierbar sein'
  end

  test 'Schiri-Rolle bleibt mit anderen Rollen unvereinbar' do
    user = build(:user, permissions: [{ 'user_group_id' => User::REFEREE_ROLE_ID },
                                      { 'user_group_id' => 4, 'club_id' => 1 }])
    assert_not user.valid?
  end

  test 'vorhandenes Konto ueber den Benutzernamen' do
    other = create(:user, :vm)
    login(@rsk)
    post "/api/v2/admin/referee_courses/#{@course.id}/leads", params: { lead: { user_name: other.user_name.upcase } },
                                                              as: :json
    assert_response :created
    assert lead_role?(other)

    post "/api/v2/admin/referee_courses/#{@course.id}/leads", params: { lead: { user_name: 'gibtsnicht' } }, as: :json
    assert_response :unprocessable_entity
  end

  test 'Entfernen der letzten Zuordnung nimmt die Rolle ab' do
    user = create(:user)
    second = RefereeCourse.create!(title: 'F-Kurs', course_type: 'f', state_association: @lv)
    a = RefereeCourseLeadAssigner.new(@course).assign(user_name: user.user_name).lead
    RefereeCourseLeadAssigner.new(second).assign(user_name: user.user_name)

    login(@rsk)
    delete "/api/v2/admin/referee_courses/#{@course.id}/leads/#{a.id}"
    assert_response :no_content
    assert lead_role?(user), 'Rolle bleibt, solange noch ein Kurs zugeordnet ist'

    RefereeCourseLeadAssigner.remove(second.leads.first)
    assert_not lead_role?(user)
  end

  test 'Kursleitung sieht nur ihre Kurse, ohne Kontaktdaten und verborgene Felder' do
    lead_user = create(:user)
    RefereeCourseLeadAssigner.new(@course).assign(user_name: lead_user.user_name)
    other = RefereeCourse.create!(title: 'Fremder Kurs', course_type: 'g', state_association: @lv)
    @course.registrations.create!(vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2008, 4, 1),
                                  email: 'ada@example.org', telefon: '0123',
                                  custom_answers: { @field_visible.id.to_s => 'keine',
                                                    @field_hidden.id.to_s => 'intern' })
    assert lead_user.reload.permissions_items[:menu_item_referee_courses_lead]

    login(lead_user)
    get '/api/v2/course_lead/courses'
    assert_response :success
    assert_equal [@course.id], response.parsed_body.pluck('id')

    get "/api/v2/course_lead/courses/#{@course.id}"
    assert_response :success
    reg = response.parsed_body['registrations'].first
    assert_nil reg['email']
    assert_nil reg['telefon']
    assert_equal({ @field_visible.id.to_s => 'keine' }, reg['custom_answers'])
    assert_equal ['Erfahrung'], response.parsed_body['fields'].pluck('label')

    get "/api/v2/course_lead/courses/#{other.id}"
    assert_response :not_found
    get '/api/v2/admin/referee_courses'
    assert_response :forbidden
  end

  test 'Kursleitung erfasst Anwesenheit und Ergebnis, aber keine Absage' do
    lead_user = create(:user)
    RefereeCourseLeadAssigner.new(@course).assign(user_name: lead_user.user_name)
    reg = @course.registrations.create!(vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2008, 4, 1))
    login(lead_user)
    patch "/api/v2/course_lead/courses/#{@course.id}/registrations/#{reg.id}",
          params: { registration: { status: 'attended', result: 'passed', points: 31, test_version: 'B' } }, as: :json
    assert_response :success
    assert_equal 'passed', reg.reload.result

    patch "/api/v2/course_lead/courses/#{@course.id}/registrations/#{reg.id}",
          params: { registration: { status: 'cancelled_by_organizer' } }, as: :json
    assert_response :unprocessable_entity
  end

  test 'Kursleitung kann wartende Anmeldungen nicht umstellen' do
    lead_user = create(:user)
    RefereeCourseLeadAssigner.new(@course).assign(user_name: lead_user.user_name)
    pending = @course.registrations.create!(vorname: 'Kim', nachname: 'Klein', geburtsdatum: Date.new(2014, 1, 1),
                                            status: 'pending_guardian', skip_required_answers: true)
    login(lead_user)
    patch "/api/v2/course_lead/courses/#{@course.id}/registrations/#{pending.id}",
          params: { registration: { status: 'attended' } }, as: :json
    assert_response :unprocessable_entity
    assert_equal 'pending_guardian', pending.reload.status
  end

  test 'Schalter aus: Kursleitung sieht nichts' do
    lead_user = create(:user)
    RefereeCourseLeadAssigner.new(@course).assign(user_name: lead_user.user_name)
    @setting.update!(referee_course_processes: { 'courses_enabled' => false })
    assert_not lead_user.reload.permissions_items[:menu_item_referee_courses_lead]
    login(lead_user)
    get "/api/v2/course_lead/courses/#{@course.id}"
    assert_response :not_found
  end

  test 'Einladungsmail nennt Kurs und Benutzernamen' do
    user = create(:user, first_name: 'Jörg', user_name: 'kl-mueller', password_reset_token: 'tok')
    mail = UserMailer.course_lead_invited(user, @course)
    assert_equal ['rsk@lv.example'], mail.reply_to
    assert_match 'G-Kurs Kassel', mail.subject
    assert_match 'kl-mueller', mail.body.encoded
    assert_match '/neues-passwort/tok', mail.body.encoded
  end
end
