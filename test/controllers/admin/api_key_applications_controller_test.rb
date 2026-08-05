require 'test_helper'

module Admin
  class ApiKeyApplicationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @application = create(:api_key_application)
    end

    test 'Admin sieht die Antraege und kann nach Status filtern' do
      decided = create(:api_key_application)
      decided.reject!(@admin.id, 'Passt nicht')

      login(@admin)
      get '/api/v2/admin/api_key_applications?status=pending'

      assert_response :success
      ids = JSON.parse(response.body).map { |a| a['id'] }
      assert_includes ids, @application.id
      assert_not_includes ids, decided.id
    end

    test 'SBK hat keinen Zugriff' do
      login(create(:user, :sbk_global))
      get '/api/v2/admin/api_key_applications'

      assert_response :forbidden
    end

    test 'Genehmigen verschickt den Abhol-Link und erzeugt noch keinen Key' do
      login(@admin)

      assert_no_difference 'ApiKey.count' do
        assert_enqueued_emails 1 do
          post "/api/v2/admin/api_key_applications/#{@application.id}/approve"
        end
      end

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'approved', body['status']
      assert_equal 'valid', body['reveal_state']
      assert_nil body['api_key_id']
      assert_not_includes response.body, 'reveal_token_digest'
    end

    test 'zweites Genehmigen wird abgewiesen' do
      login(@admin)
      post "/api/v2/admin/api_key_applications/#{@application.id}/approve"
      assert_response :success

      post "/api/v2/admin/api_key_applications/#{@application.id}/approve"
      assert_response :unprocessable_entity
      assert_includes JSON.parse(response.body)['errors'].join(' '), 'bereits entschieden'
    end

    test 'Ablehnen ohne Begruendung wird abgewiesen' do
      login(@admin)

      assert_no_enqueued_emails do
        post "/api/v2/admin/api_key_applications/#{@application.id}/reject"
      end

      assert_response :unprocessable_entity
      assert_equal 'pending', @application.reload.status
    end

    test 'Ablehnen mit Begruendung benachrichtigt den Antragsteller' do
      login(@admin)

      assert_enqueued_emails 1 do
        post "/api/v2/admin/api_key_applications/#{@application.id}/reject",
             params: { decision_note: 'Kommerzielles Vorhaben' }
      end

      assert_response :success
      assert_equal 'rejected', @application.reload.status
      assert_equal 'Kommerzielles Vorhaben', @application.decision_note
    end

    test 'neuer Abhol-Link nur fuer genehmigte, nicht abgeholte Antraege' do
      login(@admin)

      post "/api/v2/admin/api_key_applications/#{@application.id}/resend_reveal"
      assert_response :unprocessable_entity

      @application.approve!(@admin.id)
      assert_enqueued_emails 1 do
        post "/api/v2/admin/api_key_applications/#{@application.id}/resend_reveal"
      end
      assert_response :success

      @application.reload.reveal_key!
      post "/api/v2/admin/api_key_applications/#{@application.id}/resend_reveal"
      assert_response :unprocessable_entity
    end

    test 'unbekannter Antrag liefert 404' do
      login(@admin)
      post '/api/v2/admin/api_key_applications/999999/approve'

      assert_response :not_found
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
