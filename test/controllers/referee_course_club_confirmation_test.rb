require 'test_helper'
require 'csv'

# Vereinsbestaetigung: Selbstanmeldungen, bei denen ein Verein zahlt, muss der
# Verein bestaetigen, wenn der Landesverband das eingestellt hat.
class RefereeCourseClubConfirmationTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
    @go = create(:game_operation)
    @lv = @go.state_association
    @lv.update!(course_club_confirmation_required: true)
    @club = create(:club, state_association: @lv, contact_email: 'kasse@verein.example')
    @other_club = create(:club, state_association: @lv)
    @vm = create(:user, :vm, club_id: @club.id)
    @other_vm = create(:user, :vm, club_id: @other_club.id)
    @course = RefereeCourse.create!(
      title: 'G-Kurs', course_type: 'g', state_association: @lv, status: 'published', max_participants: 1,
      fee_member_cents: 2500, sessions: [{ 'starts_at' => 30.days.from_now.iso8601 }]
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def public_registration(extra = {})
    post "/api/v2/public/referee_courses/#{@course.id}/registrations",
         params: { registration: { vorname: 'Neu', nachname: 'Ling', geburtsdatum: '2000-03-04',
                                   email: 'neu@example.org', club_id: @club.id, consent: true }.merge(extra) },
         as: :json
    job = enqueued_jobs.reverse.find { |j| j[:args].include?('confirm_email') }
    post "/api/v2/public/course_registrations/confirm/#{job[:args].last['args'].last}"
    RefereeCourseRegistration.last
  end

  test 'oeffentliche Anmeldung mit Verein wartet auf den Verein, haelt keinen Platz, Verein bekommt Mail' do
    reg = nil
    assert_enqueued_emails 3 do # Bestaetigungslink, Vereinsanfrage, Eingangsbestaetigung
      reg = public_registration
    end
    assert_equal 'pending_club', reg.status
    assert_equal 0, @course.registrations.seated.count
    mail = RefereeCourseMailer.club_confirmation_request(reg, @club.notification_emails)
    assert_includes mail.to, 'kasse@verein.example'
    assert_match 'Neu Ling', mail.subject
  end

  test 'Verein bestaetigt: Platz oder Warteliste' do
    reg = public_registration
    login(@vm)
    get '/api/v2/club/referee_courses'
    assert_includes response.parsed_body['registrations'].pluck('id'), reg.id

    post "/api/v2/club/referee_courses/registrations/#{reg.id}/confirm"
    assert_response :success
    assert_equal 'registered', reg.reload.status
    assert_equal @vm.id, reg.club_confirmed_by_user_id
  end

  test 'Verein lehnt mit Grund ab, Person wird benachrichtigt' do
    reg = public_registration
    login(@vm)
    post "/api/v2/club/referee_courses/registrations/#{reg.id}/decline", params: { reason: '' }, as: :json
    assert_response :unprocessable_entity
    assert_enqueued_emails 1 do
      post "/api/v2/club/referee_courses/registrations/#{reg.id}/decline",
           params: { reason: 'Nicht unser Mitglied' }, as: :json
    end
    assert_response :success
    assert_equal 'declined_by_club', reg.reload.status
    assert reg.cancelled?
  end

  test 'fremder Verein kann nicht bestaetigen' do
    reg = public_registration
    login(@other_vm)
    post "/api/v2/club/referee_courses/registrations/#{reg.id}/confirm"
    assert_response :not_found
  end

  test 'ohne Verbandseinstellung, ohne Verein oder bei Vereinsanmeldung gibt es keinen Schritt' do
    @lv.update!(course_club_confirmation_required: false)
    assert_equal 'registered', public_registration.status

    @lv.update!(course_club_confirmation_required: true)
    @course.update!(max_participants: 10)
    reg = public_registration(vorname: 'Privat', club_id: nil, billing_address: 'Weg 1')
    assert_equal 'registered', reg.status

    login(@vm)
    post "/api/v2/club/referee_courses/#{@course.id}/registrations",
         params: { registration: { vorname: 'Vom', nachname: 'Verein', geburtsdatum: '2000-01-01',
                                   club_id: @club.id } }, as: :json
    assert_equal 'registered', response.parsed_body['status']
  end

  test 'Portal-Anmeldung eines Schiris laeuft ebenfalls ueber den Verein' do
    referee = create(:referee, club: @club, email: 'sr@example.org', geburtsdatum: Date.new(2000, 1, 1))
    user = create(:user, referee: referee, permissions: [{ 'user_group_id' => User::REFEREE_ROLE_ID }])
    login(user)
    post "/api/v2/referee/courses/#{@course.id}/registration", params: { registration: {} }, as: :json
    assert_response :created
    assert_equal 'pending_club', response.parsed_body['status']
  end

  test 'Unterverband erbt die Einstellung des Verbunds' do
    child = create(:state_association, parent: @lv)
    assert child.effective_course_club_confirmation_required
  end

  test 'Kursabsage raeumt wartende Vereinsbestaetigungen ab' do
    reg = public_registration
    login(create(:user, :admin))
    patch "/api/v2/admin/referee_courses/#{@course.id}", params: { referee_course: { status: 'cancelled' } },
                                                          as: :json
    assert_equal 'cancelled_by_organizer', reg.reload.status
  end

  test 'Verbandseinstellung ist in der Verbandsmaske pflegbar' do
    login(create(:user, :admin))
    patch "/api/v2/admin/state_associations/#{@lv.id}",
          params: { state_association: { course_club_confirmation_required: false } }, as: :json
    assert_response :success
    assert_not @lv.reload.course_club_confirmation_required
    assert response.parsed_body['referee_courses_enabled']

    @setting.update!(referee_course_processes: { 'courses_enabled' => false })
    get "/api/v2/admin/state_associations/#{@lv.id}"
    assert_equal false, response.parsed_body['referee_courses_enabled']
  end
  test 'nach einer Ablehnung kann sich die Person wieder anmelden' do
    referee = create(:referee, club: @club, email: 'sr@example.org', geburtsdatum: Date.new(2000, 1, 1))
    user = create(:user, referee: referee, permissions: [{ 'user_group_id' => User::REFEREE_ROLE_ID }])
    login(user)
    post "/api/v2/referee/courses/#{@course.id}/registration", params: { registration: {} }, as: :json
    reg = RefereeCourseRegistration.find(response.parsed_body['id'])
    RefereeCourseRegistrar.new(@course).decline_club(reg, user: @vm, reason: 'Nein')

    login(user)
    post "/api/v2/referee/courses/#{@course.id}/registration", params: { registration: {} }, as: :json
    assert_response :created
    assert_equal 'pending_club', response.parsed_body['status']
  end

  test 'doppelte Bestaetigung nimmt den Platz nicht wieder weg' do
    reg = public_registration
    stale = RefereeCourseRegistration.find(reg.id)
    registrar = RefereeCourseRegistrar.new(@course)
    assert registrar.confirm_club(reg, user: @vm).success?
    stale.status = 'pending_club' # Stand vor der ersten Bestaetigung, wie ein paralleler Request
    second = RefereeCourseRegistrar.new(@course.reload).confirm_club(stale, user: @vm)
    assert_not second.success?
    assert_equal 'registered', reg.reload.status
  end

  test 'nach dem Kurs laesst sich nicht mehr bestaetigen; Loeschlauf raeumt liegengebliebene ab' do
    reg = public_registration
    @course.update_columns(status: 'held', ends_on: 10.days.ago.to_date)
    login(@vm)
    post "/api/v2/club/referee_courses/registrations/#{reg.id}/confirm"
    assert_response :unprocessable_entity
    assert_equal 'pending_club', reg.reload.status
    assert_includes RefereeCourseRegistrationPurge.scopes.values.flat_map(&:ids), reg.id
  end

  test 'Mails: Eingang ohne Platzzusage, Ablehnung verweist an die Kursverantwortlichen' do
    @course.update!(contact_email: 'rsk@lv.example')
    reg = public_registration
    waiting = RefereeCourseMailer.awaiting_club(reg)
    assert_match 'eingegangen', waiting.subject
    assert_no_match(/bestätigt/, waiting.text_part.body.to_s)
    reg.update_columns(status: 'declined_by_club', club_decline_reason: 'Kein Mitglied')
    declined = RefereeCourseMailer.club_declined(reg).text_part.body.to_s
    assert_match 'Kursverantwortlichen', declined
    assert_match 'rsk@lv.example', declined
    assert_no_match(/selbst tragen/, declined)
    rows = CSV.parse(RefereeCourseParticipantList.new(@course).to_csv.delete_prefix("\uFEFF"), col_sep: ';',
                                                                                              headers: true)
    assert_equal 'vom Verein abgelehnt', rows.first['Status']
  end
end
