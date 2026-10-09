require 'test_helper'

# Schalter fuer die Kursprozesse in den Schiri-Einstellungen: CSV-Import an/aus,
# Kurse im System an/aus (optional je Landesverband).
module Admin
  class RefereeCourseSettingsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @setting = create(:setting)
      @admin = create(:user, :admin)
      @fd_rsk = create(:user, permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 0 }])
    end

    test 'ohne gespeicherten Wert gilt die Vorgabe: Import an, Kurse aus' do
      login(@admin)
      get '/api/v2/admin/referee_course_settings'
      assert_response :success
      body = response.parsed_body
      assert_equal true, body['csv_import_enabled']
      assert_equal false, body['courses_enabled']
      assert_equal [], body['courses_state_association_ids']
    end

    test 'Admin schaltet um, der Stand wirkt sofort ueber Setting.current' do
      sa = create(:state_association)
      # Den Cache vorher fuellen: Der Schalter muss ihn abraeumen, sonst wirkt
      # er je nach Worker erst nach Ablauf der Standzeit.
      assert Setting.referee_course_csv_import_enabled?

      login(@admin)
      patch '/api/v2/admin/referee_course_settings',
            params: { referee_course_settings: { csv_import_enabled: false, courses_enabled: true,
                                                 courses_state_association_ids: [sa.id] } },
            as: :json
      assert_response :success
      body = response.parsed_body
      assert_equal false, body['csv_import_enabled']
      assert_equal [sa.id], body['courses_state_association_ids']
      assert body['updated_by'].present?

      Current.setting = nil
      assert_not Setting.referee_course_csv_import_enabled?
      assert Setting.referee_courses_enabled?
      assert Setting.referee_courses_enabled?(sa.id)
      assert_not Setting.referee_courses_enabled?(sa.id + 1)
    end

    test 'Bearbeiter ohne Namen: Anzeige faellt auf den Benutzernamen zurueck' do
      nameless = create(:user, :admin, first_name: nil, last_name: nil)
      login(nameless)
      patch '/api/v2/admin/referee_course_settings',
            params: { referee_course_settings: { courses_enabled: true } }, as: :json
      assert_response :success
      assert_equal nameless.user_name, response.parsed_body['updated_by']
      get '/api/v2/admin/referee_course_settings'
      assert_response :success
    end

    test 'Teilaenderung laesst den anderen Schalter stehen' do
      login(@admin)
      patch '/api/v2/admin/referee_course_settings',
            params: { referee_course_settings: { courses_enabled: true } }, as: :json
      assert_response :success
      assert_equal true, response.parsed_body['csv_import_enabled']
      assert_equal true, response.parsed_body['courses_enabled']
    end

    test 'unbekannter Landesverband wird abgelehnt' do
      login(@admin)
      patch '/api/v2/admin/referee_course_settings',
            params: { referee_course_settings: { courses_state_association_ids: [999_999] } }, as: :json
      assert_response :unprocessable_entity
      assert_equal [], Setting.referee_course_processes['courses_state_association_ids']
    end

    test 'FD-RSK darf die Schalter nicht stellen' do
      login(@fd_rsk)
      patch '/api/v2/admin/referee_course_settings',
            params: { referee_course_settings: { csv_import_enabled: false } }, as: :json
      assert_response :forbidden
      assert Setting.referee_course_csv_import_enabled?
    end

    test 'abgeschalteter Import sperrt den Upload' do
      @setting.update!(referee_course_processes: { 'csv_import_enabled' => false })
      login(@fd_rsk)
      post '/api/v2/admin/referee_course_imports', params: { file: csv_upload }
      assert_response :forbidden
      assert_match(/abgeschaltet/, response.parsed_body['error'])
      assert_equal 0, RefereeCourseImport.count
    end

    test 'abgeschalteter Import laesst offene Importe weiter einreichen' do
      import = RefereeCourseImport.create!(uploaded_by_user: @fd_rsk, filename: 'kurs.csv',
                                           total_rows: 0, status: 'in_review')
      @setting.update!(referee_course_processes: { 'csv_import_enabled' => false })
      login(@fd_rsk)
      get "/api/v2/admin/referee_course_imports/#{import.id}"
      assert_response :success
    end

    test 'Menuepunkt Kursergebnisse bleibt bei abgeschaltetem Import nur mit offenen Zeilen' do
      @setting.update!(referee_course_processes: { 'csv_import_enabled' => false })
      items = @fd_rsk.permissions_items
      assert_not items[:menu_item_referee_course_import]
      assert_not items[:referee_course_import_upload]

      import = RefereeCourseImport.create!(uploaded_by_user: @fd_rsk, filename: 'kurs.csv',
                                           total_rows: 1, status: 'in_review')
      RefereeCourseResult.create!(referee_course_import: import, status: 'pending_review', match_type: 'new_entry',
                                  csv_vorname: 'Ada', csv_nachname: 'Muster')
      items = @fd_rsk.permissions_items
      assert items[:menu_item_referee_course_import]
      assert_not items[:referee_course_import_upload]

      import.update!(status: 'cancelled')
      assert_not @fd_rsk.permissions_items[:menu_item_referee_course_import]
    end

    test 'eingeschalteter Import zeigt Menue und Upload wie bisher' do
      items = @fd_rsk.permissions_items
      assert items[:menu_item_referee_course_import]
      assert items[:referee_course_import_upload]
    end

    private

    def csv_upload
      file = Tempfile.new(['kurs', '.csv'])
      file.write("Lizenznummer;Name;Vorname;Geburtsdatum\n;Muster;Ada;01.01.2000\n")
      file.rewind
      Rack::Test::UploadedFile.new(file.path, 'text/csv', original_filename: 'kurs.csv')
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
