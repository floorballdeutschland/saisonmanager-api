require 'test_helper'

module Admin
  class EmailTemplatesControllerTest < ActionDispatch::IntegrationTest
    test 'Admin sieht alle Katalog-Vorlagen' do
      login(create_admin)
      get '/api/v2/admin/email_templates'
      assert_response :success
      body = JSON.parse(response.body)
      assert(body.any? { |t| t['key'] == 'UserMailer#reset_password' })
      assert(body.all? { |t| t.key?('default_subject') && t.key?('placeholders') })
    end

    test 'Admin überschreibt den Betreff einer Vorlage' do
      login(create_admin)
      patch '/api/v2/admin/email_templates', params: {
        email_template: { mailer_class: 'UserMailer', action_name: 'reset_password', subject: 'Neuer Betreff' }
      }
      assert_response :success
      assert_equal 'Neuer Betreff', JSON.parse(response.body)['subject']
      assert EmailTemplate.exists?(mailer_class: 'UserMailer', action_name: 'reset_password')
    end

    test 'vollständig leere Anpassung entfernt den Datensatz wieder' do
      EmailTemplate.create!(mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de', subject: 'X')
      login(create_admin)
      patch '/api/v2/admin/email_templates', params: {
        email_template: { mailer_class: 'UserMailer', action_name: 'reset_password', subject: '' }
      }
      assert_response :success
      assert_not EmailTemplate.exists?(mailer_class: 'UserMailer', action_name: 'reset_password')
    end

    test 'unbekannte Vorlage → 422' do
      login(create_admin)
      patch '/api/v2/admin/email_templates', params: {
        email_template: { mailer_class: 'Nope', action_name: 'nope', subject: 'x' }
      }
      assert_response :unprocessable_entity
    end

    test 'Nicht-Admin (SBK) erhält 403' do
      login(create_user(user_group_id: 2, game_operation_id: 0))
      get '/api/v2/admin/email_templates'
      assert_response :forbidden
    end

    private

    def create_admin
      create_user(user_group_id: 1, game_operation_id: 0)
    end

    def create_user(user_group_id:, game_operation_id:)
      User.create!(
        user_name: "authuser_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
