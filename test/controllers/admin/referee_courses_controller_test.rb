require 'test_helper'

# Kurse im System: Verwaltung durch RSK und Admin (Paket 1a).
module Admin
  class RefereeCoursesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @setting = create(:setting, referee_course_processes: { 'courses_enabled' => true })
      @l2 = RefereeLicenseLevel.create!(name: 'L2', validity_years: 1, position: 2)
      @admin = create(:user, :admin)
      @go_a = create(:game_operation)
      @go_b = create(:game_operation)
      @lv_a = @go_a.state_association
      @lv_b = @go_b.state_association
      @rsk_a = create(:user, :rsk_scoped, game_operation_id: @go_a.id)
      @rsk_b = create(:user, :rsk_scoped, game_operation_id: @go_b.id)
      @vm = create(:user, :vm)
    end

    def course_for(state_association, **attrs)
      RefereeCourse.create!({ title: "Kurs #{state_association&.name}", course_type: 'g',
                              state_association: state_association }.merge(attrs))
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    test 'Schalter aus: auch Admin kommt nicht an die Kurse' do
      @setting.update!(referee_course_processes: { 'courses_enabled' => false })
      login(@admin)
      get '/api/v2/admin/referee_courses'
      assert_response :forbidden
      assert_not @admin.reload.permissions_items[:menu_item_referee_courses]
    end

    test 'LV-RSK sieht eigene Kurse und solche, an denen ihr LV Partner ist' do
      own = course_for(@lv_a)
      partner = course_for(@lv_b, partner_state_association_ids: [@lv_a.id])
      foreign = course_for(@lv_b)
      national = course_for(nil)

      login(@rsk_a)
      get '/api/v2/admin/referee_courses'
      assert_response :success
      ids = response.parsed_body.map { |c| c['id'] }
      assert_equal [own.id, partner.id].sort, ids.sort

      get "/api/v2/admin/referee_courses/#{foreign.id}"
      assert_response :forbidden
      get "/api/v2/admin/referee_courses/#{national.id}"
      assert_response :forbidden
    end

    test 'Admin sieht alle Kurse' do
      course_for(@lv_a)
      course_for(nil)
      login(@admin)
      get '/api/v2/admin/referee_courses'
      assert_equal 2, response.parsed_body.size
    end

    test 'Pilotbetrieb: RSK eines nicht freigeschalteten LV hat keinen Zugang' do
      @setting.update!(referee_course_processes: { 'courses_enabled' => true,
                                                   'courses_state_association_ids' => [@lv_a.id] })
      assert @rsk_a.permissions_items[:menu_item_referee_courses]
      assert_not @rsk_b.permissions_items[:menu_item_referee_courses]

      login(@rsk_b)
      get '/api/v2/admin/referee_courses'
      assert_response :forbidden
    end

    test 'LV-RSK legt Kurs fuer den eigenen LV an, nicht fuer fremde oder bundesweit' do
      login(@rsk_a)
      post '/api/v2/admin/referee_courses', params: { referee_course: {
        title: 'F-Kurs Frankfurt', course_type: 'f', state_association_id: @lv_a.id, license_level_ids: [@l2.id],
        sessions: [{ starts_at: '2026-11-21T09:00:00+01:00', ends_at: '2026-11-21T17:00:00+01:00',
                     location: 'Halle Nord' }],
        max_participants: 20, min_participants: 5, fee_member_cents: 2500
      } }, as: :json
      assert_response :created
      body = response.parsed_body
      assert_equal '2026-11-21', body['starts_on']
      assert_equal [@l2.id], body['license_level_ids']
      assert_equal @rsk_a.id, RefereeCourse.find(body['id']).created_by_user_id

      post '/api/v2/admin/referee_courses',
           params: { referee_course: { title: 'x', course_type: 'g', state_association_id: @lv_b.id } }, as: :json
      assert_response :forbidden
      post '/api/v2/admin/referee_courses',
           params: { referee_course: { title: 'x', course_type: 'g', state_association_id: '' } }, as: :json
      assert_response :forbidden
    end

    test 'neuer Kurs uebernimmt die Feldvorlagen seines LV' do
      RefereeCourseFieldTemplate.create!(state_association: @lv_a, label: 'Bemerkung zur Anreise', field_type: 'text')
      RefereeCourseFieldTemplate.create!(state_association: @lv_b, label: 'Fremd', field_type: 'text')
      login(@rsk_a)
      post '/api/v2/admin/referee_courses',
           params: { referee_course: { title: 'G', course_type: 'g', state_association_id: @lv_a.id } }, as: :json
      assert_response :created
      assert_equal(['Bemerkung zur Anreise'], response.parsed_body['fields'].map { |f| f['label'] })
    end

    test 'LV-RSK darf den Kurs nicht in einen fremden LV verschieben' do
      course = course_for(@lv_a)
      login(@rsk_a)
      patch "/api/v2/admin/referee_courses/#{course.id}",
            params: { referee_course: { state_association_id: @lv_b.id } }, as: :json
      assert_response :forbidden
      patch "/api/v2/admin/referee_courses/#{course.id}",
            params: { referee_course: { status: 'published' } }, as: :json
      assert_response :success
      assert_equal 'published', course.reload.status
    end

    test 'ungueltiger Statuswechsel ergibt 422' do
      course = course_for(@lv_a)
      login(@rsk_a)
      patch "/api/v2/admin/referee_courses/#{course.id}",
            params: { referee_course: { status: 'results_submitted' } }, as: :json
      assert_response :unprocessable_entity
    end

    test 'Loeschen nur fuer Entwuerfe ohne Anmeldungen' do
      course = course_for(@lv_a)
      course.registrations.create!(vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1))
      login(@rsk_a)
      delete "/api/v2/admin/referee_courses/#{course.id}"
      assert_response :unprocessable_entity

      empty = course_for(@lv_a, title: 'leer')
      delete "/api/v2/admin/referee_courses/#{empty.id}"
      assert_response :no_content
    end

    test 'VM hat keinen Zugang' do
      login(@vm)
      get '/api/v2/admin/referee_courses'
      assert_response :forbidden
    end

    # --- Felder --------------------------------------------------------------

    test 'Feld anlegen, mit Anmeldungen nur archivieren' do
      course = course_for(@lv_a)
      login(@rsk_a)
      post "/api/v2/admin/referee_courses/#{course.id}/fields",
           params: { field: { label: 'T-Shirt', field_type: 'select', options: %w[S M L], required: true } },
           as: :json
      assert_response :created
      field_id = response.parsed_body['id']

      course.registrations.create!(vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1),
                                   skip_required_answers: true)
      patch "/api/v2/admin/referee_courses/#{course.id}/fields/#{field_id}",
            params: { field: { required: false } }, as: :json
      assert_response :unprocessable_entity

      delete "/api/v2/admin/referee_courses/#{course.id}/fields/#{field_id}"
      assert_response :no_content
      assert RefereeCourseField.find(field_id).archived_at.present?
    end

    # --- Vorlagen ------------------------------------------------------------

    test 'Vorlagen nur fuer den eigenen LV, bundesweite nur global' do
      login(@rsk_a)
      post '/api/v2/admin/referee_course_field_templates',
           params: { field: { state_association_id: @lv_a.id, label: 'Ernährung', field_type: 'select',
                              options: %w[vegetarisch vegan egal] } }, as: :json
      assert_response :created

      post '/api/v2/admin/referee_course_field_templates',
           params: { field: { state_association_id: @lv_b.id, label: 'x', field_type: 'text' } }, as: :json
      assert_response :forbidden
      get '/api/v2/admin/referee_course_field_templates'
      assert_response :forbidden

      login(@admin)
      get '/api/v2/admin/referee_course_field_templates'
      assert_response :success
    end

    # --- Teilnehmerliste -----------------------------------------------------

    test 'RSK traegt Bestandsschiri ein, Daten kommen vom Schiri' do
      club = create(:club, state_association: @lv_a)
      referee = create(:referee, vorname: 'Ada', nachname: 'Muster', geburtsdatum: Date.new(2001, 5, 4),
                                 email: 'ada@example.org', club: club, lizenznummer: 4711)
      course = course_for(@lv_a)
      login(@rsk_a)
      post "/api/v2/admin/referee_courses/#{course.id}/registrations",
           params: { registration: { referee_id: referee.id } }, as: :json
      assert_response :created
      body = response.parsed_body
      assert_equal 'Ada', body['vorname']
      assert_equal 'confirmed_existing', body['identity_match']
      assert_equal club.id, body['club']['id']
      assert_equal '4711', body['stated_lizenznummer']

      post "/api/v2/admin/referee_courses/#{course.id}/registrations",
           params: { registration: { referee_id: referee.id } }, as: :json
      assert_response :unprocessable_entity
    end

    test 'voller Kurs fuehrt auf die Warteliste, ausser die RSK macht eine Ausnahme' do
      course = course_for(@lv_a, max_participants: 1)
      login(@rsk_a)
      person = { vorname: 'Neu', nachname: 'Person', geburtsdatum: '2010-03-01' }
      post "/api/v2/admin/referee_courses/#{course.id}/registrations", params: { registration: person }, as: :json
      assert_equal 'registered', response.parsed_body['status']

      post "/api/v2/admin/referee_courses/#{course.id}/registrations",
           params: { registration: person.merge(vorname: 'Zwei') }, as: :json
      assert_equal 'waitlisted', response.parsed_body['status']

      post "/api/v2/admin/referee_courses/#{course.id}/registrations",
           params: { registration: person.merge(vorname: 'Drei', over_capacity: true) }, as: :json
      assert_equal 'registered', response.parsed_body['status']
    end

    test 'Teilnahme und Ergebnis erfassen, Absage behaelt die Zeile' do
      course = course_for(@lv_a, license_level_ids: [@l2.id])
      reg = course.registrations.create!(vorname: 'A', nachname: 'B', geburtsdatum: Date.new(2000, 1, 1))
      login(@rsk_a)
      patch "/api/v2/admin/referee_courses/#{course.id}/registrations/#{reg.id}",
            params: { registration: { status: 'attended', result: 'passed', points: 27.5,
                                      awarded_license_level_id: @l2.id } }, as: :json
      assert_response :success
      assert_equal 'passed', reg.reload.result
      assert_equal 27.5, reg.points.to_f

      patch "/api/v2/admin/referee_courses/#{course.id}/registrations/#{reg.id}",
            params: { registration: { status: 'pending_email' } }, as: :json
      assert_response :unprocessable_entity

      delete "/api/v2/admin/referee_courses/#{course.id}/registrations/#{reg.id}"
      assert_response :no_content
      assert_equal 'cancelled_by_organizer', reg.reload.status
      assert reg.cancelled_at.present?
    end

    test 'Teilnehmerliste eines fremden Kurses bleibt zu' do
      course = course_for(@lv_b)
      login(@rsk_a)
      get "/api/v2/admin/referee_courses/#{course.id}/registrations"
      assert_response :forbidden
    end

    test 'Auswahllisten: LV-RSK bekommt nur den eigenen LV zum Zuordnen' do
      login(@rsk_a)
      get '/api/v2/admin/referee_courses/options'
      assert_response :success
      body = response.parsed_body
      assert_equal [@lv_a.id], body['state_associations'].pluck('id')
      assert_includes body['partner_state_associations'].pluck('id'), @lv_b.id
      assert_equal false, body['national_allowed']
      assert_equal ['L2'], body['license_levels'].pluck('name')

      login(@admin)
      get '/api/v2/admin/referee_courses/options'
      assert_equal true, response.parsed_body['national_allowed']
    end
  end
end
