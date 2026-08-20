require 'test_helper'

# Die Verbandsmaske sperrt den Block „Einstellungen" bei einem untergeordneten
# Landesverband. Ein direkter API-Aufruf umgeht die Maske, deshalb verwirft der
# Controller die Felder – sonst schriebe ein regionaler SBK weiter Werte, die
# niemand mehr liest, und die beim Lösen des Verbunds wieder auftauchten.
module Admin
  class StateAssociationInheritedSettingsTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @verbund = create(:state_association, scan_required: true)
      @child = create(:state_association, parent: @verbund)
    end

    test 'Admin kann die Einstellungen eines Kind-LV nicht ueberschreiben' do
      login(create(:user, :admin))

      patch "/api/v2/admin/state_associations/#{@child.id}",
            params: { state_association: { scan_required: true,
                                           report_form_email_enabled: true,
                                           manual_proceeding_creation: true,
                                           express_license_enabled: true,
                                           referee_license_review_enabled: true,
                                           referee_assignment_external_enabled: true,
                                           referee_assignment_enabled: true,
                                           person_level_assignment_default: true } }

      assert_response :success
      @child.reload
      StateAssociation::INHERITED_SETTINGS.each do |setting|
        assert_not @child.public_send(setting), "#{setting} wurde am Kind-LV gespeichert"
      end
    end

    test 'Stammdaten des Kind-LV bleiben trotzdem pflegbar' do
      login(create(:user, :admin))

      patch "/api/v2/admin/state_associations/#{@child.id}",
            params: { state_association: { short_name: 'NEU', scan_required: true } }

      assert_response :success
      assert_equal 'NEU', @child.reload.short_name
      assert_not @child.scan_required
    end

    test 'ohne Verbund bleiben die Einstellungen pflegbar' do
      login(create(:user, :admin))

      patch "/api/v2/admin/state_associations/#{@verbund.id}",
            params: { state_association: { report_form_email_enabled: true } }

      assert_response :success
      assert @verbund.reload.report_form_email_enabled
    end

    # parent_id darf nur ein globaler Admin schicken; für alle anderen streicht
    # `permit` den Schlüssel. Die Sperre darf deshalb nicht allein am Parameter
    # hängen, sonst schriebe der SBK des Kind-LV weiter durch.
    test 'SBK des Kind-LV schreibt die Einstellungen nicht durch' do
      go = create(:game_operation, state_association: @child)
      login(create(:user, :sbk_scoped, game_operation_id: go.id))

      patch "/api/v2/admin/state_associations/#{@child.id}",
            params: { state_association: { scan_required: true } }

      assert_response :success
      assert_not @child.reload.scan_required
    end

    test 'Detail-Endpunkt liefert die geerbten Werte' do
      login(create(:user, :admin))

      get "/api/v2/admin/state_associations/#{@child.id}"

      assert_response :success
      body = response.parsed_body
      assert body['effective_scan_required']
      assert_not body['scan_required']
      assert_not body['effective_report_form_email_enabled']
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
