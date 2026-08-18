require 'test_helper'

module Admin
  class DocumentTypesControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @sa = create(:state_association)
      @go = create(:game_operation, state_association_id: @sa.id)
      @other_go = create(:game_operation, state_association_id: @sa.id)
      @global = DocumentType.create!(name: 'Unterstellungserklärung')
      @scoped = DocumentType.create!(name: 'LV-Attest', game_operation_id: @go.id)
      @foreign = DocumentType.create!(name: 'Fremd-Dokument', game_operation_id: @other_go.id)
    end

    test 'Admin sieht alle Einträge und legt globale an' do
      login(create(:user, :admin))

      get '/api/v2/admin/document_types'
      assert_response :success
      assert_equal 3, JSON.parse(response.body).size

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Schiedsvereinbarung Anti-Doping', required_below_age: nil }
      }
      assert_response :created
      body = JSON.parse(response.body)
      assert_nil body['game_operation_id']
      assert_equal 'schiedsvereinbarung_anti_doping', body['key']
    end

    test 'gescopte SBK sieht nur eigene und globale Einträge' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      get '/api/v2/admin/document_types'
      assert_response :success
      keys = JSON.parse(response.body).map { |d| d['key'] }
      assert_includes keys, @global.key
      assert_includes keys, @scoped.key
      assert_not_includes keys, @foreign.key
    end

    test 'gescopte SBK darf keine Dokumentart anlegen (nur lesen)' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Vereins-Attest', required_below_age: 16 }
      }
      assert_response :forbidden
    end

    test 'gescopte SBK darf keine Dokumentart ändern (auch nicht die eigene)' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      patch "/api/v2/admin/document_types/#{@scoped.id}", params: { document_type: { name: 'Umbenannt' } }
      assert_response :forbidden
      assert_equal 'LV-Attest', @scoped.reload.name
    end

    test 'gescopte SBK darf keine Dokumentart löschen' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      delete "/api/v2/admin/document_types/#{@scoped.id}"
      assert_response :forbidden
      assert DocumentType.exists?(@scoped.id)
    end

    test 'globale SBK (FD) darf Dokumentarten anlegen und ändern' do
      login(create(:user, :sbk_global))

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Bundesweites Attest', game_operation_id: @go.id }
      }
      assert_response :created
      assert_equal @go.id, JSON.parse(response.body)['game_operation_id']

      patch "/api/v2/admin/document_types/#{@foreign.id}", params: { document_type: { name: 'Umbenannt' } }
      assert_response :success
      assert_equal 'Umbenannt', @foreign.reload.name
    end

    test 'Löschen ist blockiert, solange die Dokumentart verwendet wird' do
      league = create(:league, game_operation: @go, required_documents: [@scoped.key])
      login(create(:user, :admin))

      delete "/api/v2/admin/document_types/#{@scoped.id}"
      assert_response :unprocessable_entity
      assert DocumentType.exists?(@scoped.id)

      league.update!(required_documents: [])
      delete "/api/v2/admin/document_types/#{@scoped.id}"
      assert_response :no_content
      assert_not DocumentType.exists?(@scoped.id)
    end

    # Die Altersregel muss ueber die Maske in beiden Formen pflegbar sein und in der
    # Antwort auch wieder ankommen — sonst kann die Liste keine Kennzeichnung zeigen
    # und das Bearbeiten-Formular nichts vorbelegen (#483).
    test 'Geburtsjahrgang laesst sich pflegen und kommt in der Antwort zurueck' do
      login(create(:user, :admin))

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Sportärztliches Attest', required_from_birth_year: 2012 }
      }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 2012, body['required_from_birth_year']
      assert_nil body['required_below_age']

      get '/api/v2/admin/document_types'
      listed = JSON.parse(response.body).find { |d| d['key'] == 'sportarztliches_attest' }
      assert_equal 2012, listed['required_from_birth_year']
    end

    # Der Wechsel der Regelart: Das Formular schickt die nicht gewaehlte Form leer
    # mit, und leer muss die alte Angabe auch tatsaechlich abraeumen.
    test 'Wechsel von Stichtagsalter auf Jahrgang raeumt die alte Angabe ab' do
      attest = DocumentType.create!(name: 'Attest FD', required_below_age: 16)
      login(create(:user, :admin))

      patch "/api/v2/admin/document_types/#{attest.id}", params: {
        document_type: { required_below_age: '', required_from_birth_year: 2012 }
      }
      assert_response :success
      attest.reload
      assert_nil attest.required_below_age
      assert_equal 2012, attest.required_from_birth_year
    end

    test 'beide Altersregeln zusammen werden abgelehnt' do
      login(create(:user, :admin))

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Doppelregel', required_below_age: 16, required_from_birth_year: 2012 }
      }
      assert_response :unprocessable_entity
      assert_match(/nur eine Altersregel/, JSON.parse(response.body)['errors'].join(' '))
      assert_not DocumentType.exists?(name: 'Doppelregel')
    end

    test 'VM hat keinen Zugriff' do
      login(create(:user, :vm, club_id: 1))

      get '/api/v2/admin/document_types'
      assert_response :forbidden
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
