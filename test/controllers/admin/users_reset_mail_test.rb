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

    # Mailer-Ersatz, der an der Vorlage scheitert statt am Transport: Der
    # Mailtext kommt aus der Tabelle email_templates und wird erst in
    # deliver_now ausgewertet, eine dort eingetragene kaputte Absenderadresse
    # schlägt genau so durch.
    def broken_template_mail
      broken = Object.new
      def broken.deliver_now
        raise Mail::Field::IncompleteParseError.new(Mail::FromField, 'noreply@saisonmanager,org', nil)
      end
      broken
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

    # Gegenprobe zum Transportfehler: Eine kaputte Mailvorlage ist keine
    # vorübergehende Störung, sondern eine Fehlkonfiguration, die ohne lauten
    # Fehler den Passwort-Reset systemweit stumm ausser Betrieb setzen würde.
    # Sie muss durchschlagen.
    test 'ein Fehler in der Mailvorlage wird nicht verschluckt' do
      login(@admin)

      UserMailer.stub(:reset_password, ->(*, **) { broken_template_mail }) do
        assert_raises(Mail::Field::IncompleteParseError) do
          post "/api/v2/admin/users/#{@managed.id}/trigger_password_reset"
        end
      end
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
