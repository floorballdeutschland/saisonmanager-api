require 'test_helper'

# Die drei Ansetzungs-Optionen sind gestaffelt (#403). Die Maske graut die
# untergeordneten aus, ein API-Aufruf umgeht sie – deshalb räumt der Controller
# widersprüchliche Kombinationen beim Speichern auf, statt sie zu speichern und
# überall beim Lesen zu entschärfen.
module Admin
  class StateAssociationAssignmentSwitchesTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      login(create(:user, :admin))
    end

    test 'Personenebene ohne Hauptschalter wird nicht gespeichert' do
      sa = create(:state_association)

      patch "/api/v2/admin/state_associations/#{sa.id}",
            params: { state_association: { referee_assignment_external_enabled: false,
                                           referee_assignment_enabled: true } }

      assert_response :success
      sa.reload
      assert_not sa.referee_assignment_enabled
      assert_equal :none, sa.referee_assignment_mode
    end

    test 'Voreinstellung ohne Personenebene wird nicht gespeichert' do
      sa = create(:state_association)

      patch "/api/v2/admin/state_associations/#{sa.id}",
            params: { state_association: { referee_assignment_external_enabled: true,
                                           referee_assignment_enabled: false,
                                           person_level_assignment_default: true } }

      assert_response :success
      sa.reload
      assert_not sa.person_level_assignment_default
      assert_equal :club, sa.referee_assignment_mode
    end

    test 'alle drei zusammen bleiben stehen' do
      sa = create(:state_association)

      patch "/api/v2/admin/state_associations/#{sa.id}",
            params: { state_association: { referee_assignment_external_enabled: true,
                                           referee_assignment_enabled: true,
                                           person_level_assignment_default: true } }

      assert_response :success
      sa.reload
      assert_equal :person, sa.referee_assignment_mode
      assert sa.person_level_assignment_default_active?
    end

    # Wird der Hauptschalter später abgeschaltet, dürfen die untergeordneten
    # Optionen nicht gesetzt liegen bleiben – sonst tauchten sie beim
    # Wiedereinschalten unerwartet aktiv wieder auf.
    test 'Hauptschalter abschalten raeumt die untergeordneten Optionen mit ab' do
      sa = create(:state_association, referee_assignment_enabled: true,
                                      person_level_assignment_default: true)

      patch "/api/v2/admin/state_associations/#{sa.id}",
            params: { state_association: { referee_assignment_external_enabled: false } }

      assert_response :success
      sa.reload
      assert_not sa.referee_assignment_enabled
      assert_not sa.person_level_assignment_default
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
