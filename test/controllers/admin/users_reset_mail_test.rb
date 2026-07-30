require 'test_helper'

module Admin
  # Verhalten der Verwaltung, wenn der Mailversand scheitert. Der Versand läuft
  # synchron im Request; vorher riss ein SMTP-Timeout den ganzen Aufruf mit
  # (Sentry SAISONMANAGER-1X): beim Anlegen war das Konto dann schon gespeichert,
  # der Aufrufer sah aber einen Serverfehler.
  class UsersResetMailTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @admin = create(:user, :admin)
      @managed = create(:user, email: 'konto@example.org')
    end

    # Mailer-Ersatz, dessen Versand wie ein hängender SMTP-Server abbricht.
    def failing_mail
      failing = Object.new
      def failing.deliver_now
        raise Net::ReadTimeout
      end
      failing
    end

    test 'trigger_password_reset meldet einen gescheiterten Versand' do
      login(@admin)

      UserMailer.stub(:reset_password, ->(*, **) { failing_mail }) do
        post "/api/v2/admin/users/#{@managed.id}/trigger_password_reset"
      end

      assert_response :bad_gateway
      body = JSON.parse(response.body)
      refute body['success']
      assert_includes body['message'], 'nicht versendet'
    end

    test 'trigger_password_reset bestätigt den erfolgreichen Versand' do
      login(@admin)

      assert_emails 1 do
        post "/api/v2/admin/users/#{@managed.id}/trigger_password_reset"
      end

      assert_response :success
      assert JSON.parse(response.body)['success']
    end

    test 'Kontoanlage bleibt erfolgreich, wenn die Willkommensmail scheitert' do
      login(@admin)

      UserMailer.stub(:reset_password, ->(*, **) { failing_mail }) do
        post '/api/v2/admin/users', params: {
          user: { user_name: 'ohne.mail', first_name: 'Ohne', last_name: 'Mail', email: 'ohne@example.org' },
          role: { user_group_id: 1 }
        }
      end

      # Das Konto existiert – ein 500er hätte den Aufrufer dazu verleitet, es
      # erneut anzulegen, was am eindeutigen Benutzernamen scheitert.
      assert_response :created
      refute JSON.parse(response.body)['email_sent']
      assert User.exists?(user_name: 'ohne.mail')
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
