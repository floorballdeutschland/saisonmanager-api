require 'test_helper'

module Admin
  # Pflege der Sperrliste. Nur Admin: Eine Sperre wirkt vor allem anderen.
  class BlockedIpsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @sa = create(:state_association)
      @go = create(:game_operation, state_association_id: @sa.id)
    end

    test 'Admin listet, legt an und entfernt' do
      login(@admin)

      post '/api/v2/admin/blocked_ips', params: { blocked_ip: { ip: '198.51.100.5', reason: 'Dauerhaft 401' } }
      assert_response :created
      id = JSON.parse(response.body)['id']
      assert_equal @admin.id, BlockedIp.find(id).created_by, 'der Urheber gehoert in die Historie'

      get '/api/v2/admin/blocked_ips'
      assert_response :success
      eintrag = JSON.parse(response.body).find { |b| b['id'] == id }
      assert_equal '198.51.100.5', eintrag['ip']
      assert_equal 'Dauerhaft 401', eintrag['reason']
      assert_equal @admin.full_with_username, eintrag['created_by_name']

      delete "/api/v2/admin/blocked_ips/#{id}"
      assert_response :no_content
      assert_not BlockedIp.exists?(id)
    end

    test 'eine unsinnige Adresse wird mit lesbarer Meldung abgelehnt' do
      login(@admin)

      post '/api/v2/admin/blocked_ips', params: { blocked_ip: { ip: 'keine-ip', reason: 'Test' } }
      assert_response :unprocessable_entity
      assert_match(/IP-Adresse/, JSON.parse(response.body)['errors'].join(' '))
    end

    # Der Riegel muss auch ueber die Maske gelten, nicht nur im Modell.
    test 'das eigene Netz laesst sich nicht sperren' do
      login(@admin)

      post '/api/v2/admin/blocked_ips', params: { blocked_ip: { ip: '172.18.0.3', reason: 'Test' } }
      assert_response :unprocessable_entity
      assert_match(/privaten Netz/, JSON.parse(response.body)['errors'].join(' '))
      assert_not BlockedIp.exists?(ip: '172.18.0.3')
    end

    test 'SBK darf die Sperrliste weder sehen noch aendern' do
      login(create(:user, :sbk_global))

      get '/api/v2/admin/blocked_ips'
      assert_response :forbidden

      post '/api/v2/admin/blocked_ips', params: { blocked_ip: { ip: '198.51.100.5', reason: 'Test' } }
      assert_response :forbidden
      assert_not BlockedIp.exists?(ip: '198.51.100.5')

      # Auch das zerstoerende Verb: authorize_admin! hat heute kein `only:`, ein
      # spaeteres liesse ausgerechnet das Loeschen offen.
      vorhanden = BlockedIp.create!(ip: '198.51.100.6', reason: 'Test')
      delete "/api/v2/admin/blocked_ips/#{vorhanden.id}"
      assert_response :forbidden
      assert BlockedIp.exists?(vorhanden.id)
    end

    test 'ohne Anmeldung kein Zugriff' do
      get '/api/v2/admin/blocked_ips'
      assert_response :unauthorized
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
