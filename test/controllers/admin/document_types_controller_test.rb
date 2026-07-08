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

    test 'gescopte SBK legt ohne Verbandsangabe einen verbandseigenen Eintrag an' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      post '/api/v2/admin/document_types', params: {
        document_type: { name: 'Vereins-Attest', required_below_age: 16 }
      }
      assert_response :created
      assert_equal @go.id, JSON.parse(response.body)['game_operation_id']
    end

    test 'gescopte SBK darf globale und fremde Einträge nicht ändern' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      patch "/api/v2/admin/document_types/#{@global.id}", params: { document_type: { name: 'Umbenannt' } }
      assert_response :forbidden

      patch "/api/v2/admin/document_types/#{@foreign.id}", params: { document_type: { name: 'Umbenannt' } }
      assert_response :forbidden

      patch "/api/v2/admin/document_types/#{@scoped.id}", params: { document_type: { name: 'Umbenannt' } }
      assert_response :success
      assert_equal 'Umbenannt', @scoped.reload.name
    end

    test 'gescopte SBK kann den eigenen Eintrag nicht global oder fremd umscopen' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      patch "/api/v2/admin/document_types/#{@scoped.id}",
            params: { document_type: { name: 'LV-Attest', game_operation_id: nil } }
      assert_response :success
      assert_equal @go.id, @scoped.reload.game_operation_id, 'darf nicht zum globalen Eintrag werden'

      patch "/api/v2/admin/document_types/#{@scoped.id}",
            params: { document_type: { name: 'LV-Attest', game_operation_id: @other_go.id } }
      assert_response :success
      assert_equal @go.id, @scoped.reload.game_operation_id, 'darf nicht in fremden Verband wandern'
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
