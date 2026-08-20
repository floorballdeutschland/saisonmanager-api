require 'test_helper'

module Admin
  # E-Mail-Import aus CSV, Konto-Badge der Liste und Massenanlage von
  # Schiedsrichter-Benutzerkonten.
  class RefereeAccountToolsTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @sa = create(:state_association)
      @go = create(:game_operation, state_association_id: @sa.id)
      @club = create(:club, state_association_id: @sa.id)
    end

    # --- Konto-Badge in der Liste ---

    test 'Liste liefert has_user fuer den Admin' do
      with_account = create(:referee, club_id: @club.id, email: 'a@example.org', gueltigkeit: 1.year.from_now)
      without = create(:referee, club_id: @club.id, email: 'b@example.org', gueltigkeit: 1.year.from_now)
      referee_login_user(with_account)
      login(admin_user)

      get '/api/v2/admin/referees', params: { status: 'alle' }
      assert_response :success

      by_id = JSON.parse(response.body).index_by { |r| r['id'] }
      assert_equal true, by_id[with_account.id]['has_user']
      assert_equal false, by_id[without.id]['has_user']
    end

    test 'Ansetzer sieht das Konto-Badge' do
      referee = create(:referee, club_id: @club.id, email: 'a@example.org', gueltigkeit: 1.year.from_now)
      referee_login_user(referee)
      login(role_user(7, @go.id))

      get '/api/v2/admin/referees', params: { status: 'alle' }
      assert_response :success

      assert_equal true, JSON.parse(response.body).find { |r| r['id'] == referee.id }['has_user']
    end

    test 'RSK sieht das Konto-Badge' do
      referee = create(:referee, club_id: @club.id, email: 'a@example.org', gueltigkeit: 1.year.from_now)
      referee_login_user(referee)
      login(role_user(3, @go.id))

      get '/api/v2/admin/referees', params: { status: 'alle' }
      assert_response :success

      assert_equal true, JSON.parse(response.body).find { |r| r['id'] == referee.id }['has_user']
    end

    # Der Vereinsmanager bekommt die Liste seiner Vereinsschiris, aber ohne
    # Kontaktdaten — und damit auch ohne die Auskunft, wer ein Konto hat.
    test 'Vereinsmanager sieht das Konto-Badge nicht' do
      referee = create(:referee, club_id: @club.id, email: 'a@example.org', gueltigkeit: 1.year.from_now)
      referee_login_user(referee)
      login(vm_user(@club.id))

      get '/api/v2/admin/referees', params: { status: 'alle' }
      assert_response :success

      row = JSON.parse(response.body).find { |r| r['id'] == referee.id }
      assert_not_nil row
      assert_not row.key?('has_user')
    end

    # --- E-Mail-Import ---

    test 'Admin importiert Adressen aus einer CSV' do
      referee = create(:referee, lizenznummer: 51_001, email: nil)
      login(admin_user)

      post '/api/v2/admin/referees/import_emails', params: { file: csv_upload("Lizenznummer;E-Mailadresse\n51001;neu@example.org\n") }
      assert_response :success

      assert_equal 'neu@example.org', referee.reload.email
      assert_equal 1, JSON.parse(response.body)['updated'].size
    end

    test 'RSK darf keine Adressen importieren' do
      referee = create(:referee, lizenznummer: 51_002, email: nil)
      login(role_user(3, @go.id))

      post '/api/v2/admin/referees/import_emails', params: { file: csv_upload("Lizenznummer;E-Mailadresse\n51002;neu@example.org\n") }
      assert_response :forbidden

      assert_nil referee.reload.email
    end

    # Die Nachbar-Helfer im Controller sind lockerer (can_create_referee_login? ist
    # admin||rsk, can_view_contact_data? auch Ansetzer). Wird die Grenze der
    # Massen-Werkzeuge versehentlich daran angeglichen, koennte ein FD-RSK Mails an
    # den Bestand aller Verbaende schicken - deshalb jede Rolle gegen jeden der
    # drei Endpunkte.
    test 'nur die Verwaltung erreicht die Konto-Werkzeuge' do
      %w[import_emails missing_user_count create_missing_users].each do |endpoint|
        [role_user(3, @go.id), role_user(3, 0), role_user(7, 0), vm_user(@club.id)].each do |user|
          login(user)

          if endpoint == 'missing_user_count'
            get "/api/v2/admin/referees/#{endpoint}"
          else
            post "/api/v2/admin/referees/#{endpoint}"
          end

          assert_response :forbidden, "#{endpoint} war fuer #{user.permissions.inspect} erreichbar"
        end
      end
    end

    test 'Verwaltung erreicht die Zaehlung' do
      login(admin_user)

      get '/api/v2/admin/referees/missing_user_count'
      assert_response :success
    end

    test 'Import ohne Datei meldet einen Fehler' do
      login(admin_user)

      post '/api/v2/admin/referees/import_emails'
      assert_response :unprocessable_entity
      assert_match(/CSV-Datei fehlt/, JSON.parse(response.body)['error'])
    end

    test 'Import mit einem Nicht-Datei-Parameter meldet 422 statt zu stuerzen' do
      login(admin_user)

      post '/api/v2/admin/referees/import_emails', params: { file: 'kein-upload' }
      assert_response :unprocessable_entity
      assert_match(/keine Datei/, JSON.parse(response.body)['error'])
    end

    test 'Import mit fehlenden Pflichtspalten meldet den Grund' do
      login(admin_user)

      post '/api/v2/admin/referees/import_emails', params: { file: csv_upload("Nummer;Adresse\n1;a@example.org\n") }
      assert_response :unprocessable_entity
      assert_match(/Pflichtspalten/, JSON.parse(response.body)['error'])
    end

    # --- Massenanlage ---

    test 'Zaehlung nennt nur Schiedsrichter mit Adresse, ohne Konto und mit Lizenznachweis' do
      create(:referee, email: 'kandidat@example.org', gueltigkeit: 1.year.from_now)
      create(:referee, email: nil, gueltigkeit: 1.year.from_now)
      create(:referee, email: 'beendet@example.org', gueltigkeit: Date.new(2019, 1, 1))
      create(:referee, email: 'ohne-nachweis@example.org', gueltigkeit: nil)
      mit_konto = create(:referee, email: 'hat@example.org', gueltigkeit: 1.year.from_now)
      referee_login_user(mit_konto)
      login(admin_user)

      get '/api/v2/admin/referees/missing_user_count'
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 1, body['count']
      assert_equal 100, body['batch_size']
    end

    test 'Massenanlage legt Konten an und verschickt die Willkommensmail ueber die Queue' do
      referee = create(:referee, email: 'massen@example.org', gueltigkeit: 1.year.from_now)
      login(admin_user)

      assert_enqueued_emails 1 do
        assert_difference -> { User.count }, 1 do
          post '/api/v2/admin/referees/create_missing_users'
        end
      end
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 1, body['created'].size
      assert_equal "sr-#{referee.lizenznummer}", body['created'].first['user_name']
      assert_equal 0, body['remaining']
      assert_equal referee.id, User.find_by(referee_id: referee.id).referee_id
    end

    test 'Massenanlage ueberspringt Beendete, Kontolose ohne Adresse und Gaeste' do
      create(:referee, email: 'beendet@example.org', gueltigkeit: Date.new(2019, 1, 1))
      create(:referee, email: nil, gueltigkeit: 1.year.from_now)
      # Gast MIT Lizenznummer: Sonst greift schon where.not(lizenznummer: nil) und
      # der Test bemerkt nicht, wenn guest: false wegfaellt.
      create(:referee, guest: true, lizenznummer: 90_001, email: 'gast@example.org',
                       gueltigkeit: 1.year.from_now)
      login(admin_user)

      assert_no_difference -> { User.count } do
        post '/api/v2/admin/referees/create_missing_users'
      end
      assert_response :success
      assert_equal 0, JSON.parse(response.body)['created'].size
    end

    test 'Massenanlage arbeitet in Tranchen und meldet den Rest' do
      3.times { |i| create(:referee, email: "tranche#{i}@example.org", gueltigkeit: 1.year.from_now) }
      login(admin_user)

      with_batch_size(2) do
        assert_difference -> { User.count }, 2 do
          post '/api/v2/admin/referees/create_missing_users'
        end
      end
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 2, body['created'].size
      assert_equal 1, body['remaining']
    end

    test 'Massenanlage meldet je Konto, ob die Willkommensmail rausging' do
      create(:referee, email: 'mail@example.org', gueltigkeit: 1.year.from_now)
      login(admin_user)

      post '/api/v2/admin/referees/create_missing_users'
      assert_response :success

      assert_equal true, JSON.parse(response.body)['created'].first['email_sent']
    end

    # Die einzige Warnung, dass der Passwort-Link an eine Adresse geht, die schon
    # zu einem anderen Konto gehoert (users.email hat keinen Unique-Index).
    test 'Massenanlage kennzeichnet eine doppelt vergebene Adresse' do
      create(:referee, lizenznummer: 61_001, email: 'einzig@example.org', gueltigkeit: 1.year.from_now)
      create(:referee, lizenznummer: 61_002, email: 'doppelt@example.org', gueltigkeit: 1.year.from_now)
      User.create!(user_name: "fremd_#{SecureRandom.hex(4)}", password: 'password123',
                   password_confirmation: 'password123', email: 'doppelt@example.org',
                   permissions: [], teams: [])
      login(admin_user)

      post '/api/v2/admin/referees/create_missing_users'
      assert_response :success

      by_number = JSON.parse(response.body)['created'].index_by { |c| c['lizenznummer'] }
      assert_equal false, by_number[61_001]['duplicate_email']
      assert_equal true, by_number[61_002]['duplicate_email']
    end

    test 'zweite Tranche holt den Rest und faehrt remaining auf 0' do
      3.times { |i| create(:referee, email: "rest#{i}@example.org", gueltigkeit: 1.year.from_now) }
      login(admin_user)

      with_batch_size(2) { post '/api/v2/admin/referees/create_missing_users' }
      assert_equal 1, JSON.parse(response.body)['remaining']

      with_batch_size(2) { post '/api/v2/admin/referees/create_missing_users' }
      body = JSON.parse(response.body)
      assert_equal 1, body['created'].size
      assert_equal 0, body['remaining']
    end

    test 'Massenanlage legt kein Konto fuer eine zusammengefuehrte Dublette an' do
      master = create(:referee, lizenznummer: 62_001, email: 'master@example.org', gueltigkeit: 1.year.from_now)
      secondary = create(:referee, lizenznummer: 62_002, email: 'dublette@example.org',
                                   gueltigkeit: 1.year.from_now)
      secondary.merge_into!(master)
      login(admin_user)

      post '/api/v2/admin/referees/create_missing_users'
      assert_response :success

      assert_nil User.find_by(referee_id: secondary.id)
      created = JSON.parse(response.body)['created'].map { |c| c['lizenznummer'] }
      assert_equal [62_001], created
    end

    # Ohne rescue je Datensatz nimmt eine Ausnahme bei Datensatz n den ganzen
    # Report mit - die Konten davor sind angelegt, ihre Mails unterwegs, und der
    # Admin sieht nur "konnte nicht angelegt werden".
    test 'eine Ausnahme bei einem Datensatz stoppt die Tranche nicht' do
      boom = create(:referee, lizenznummer: 63_001, email: 'boom@example.org', gueltigkeit: 1.year.from_now)
      create(:referee, lizenznummer: 63_002, email: 'gut@example.org', gueltigkeit: 1.year.from_now)
      login(admin_user)

      original = RefereeAccountCreator.method(:new)
      exploding = lambda do |referee, **kwargs|
        raise ActiveRecord::RecordNotUnique, 'index_users_on_referee_id_unique' if referee.id == boom.id

        original.call(referee, **kwargs)
      end

      RefereeAccountCreator.stub(:new, exploding) do
        assert_difference -> { User.count }, 1 do
          post '/api/v2/admin/referees/create_missing_users'
        end
      end
      assert_response :success

      body = JSON.parse(response.body)
      created = body['created'].map { |c| c['lizenznummer'] }
      failed = body['failed'].map { |f| f['lizenznummer'] }
      assert_equal [63_002], created
      assert_equal [63_001], failed
      assert_match(/RecordNotUnique/, body['failed'].first['error'])
    end

    # Der Wert steckt die Zusage fest, je Aufruf hoechstens 100 Willkommensmails
    # zu verschicken.
    test 'Tranchengroesse ist 100' do
      assert_equal 100, Admin::RefereesController::MAX_BULK_USER_CREATIONS
    end

    test 'RSK darf die Massenanlage nicht ausloesen' do
      create(:referee, email: 'massen@example.org', gueltigkeit: 1.year.from_now)
      login(role_user(3, @go.id))

      assert_no_difference -> { User.count } do
        post '/api/v2/admin/referees/create_missing_users'
      end
      assert_response :forbidden
    end

    test 'Massenanlage meldet den Fehlschlag statt ihn zu verschlucken' do
      referee = create(:referee, email: 'kollision@example.org', gueltigkeit: 1.year.from_now)
      # Benutzername schon belegt (etwa durch ein Konto ohne Schiri-Verknüpfung).
      User.create!(user_name: "sr-#{referee.lizenznummer}", password: 'password123',
                   password_confirmation: 'password123', permissions: [], teams: [])
      login(admin_user)

      assert_no_difference -> { User.where.not(referee_id: nil).count } do
        post '/api/v2/admin/referees/create_missing_users'
      end
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 0, body['created'].size
      assert_equal 1, body['failed'].size
      assert_equal 1, body['remaining']
    end

    private

    def csv_upload(content)
      Rack::Test::UploadedFile.new(StringIO.new(content), 'text/csv', original_filename: 'mails.csv')
    end

    def with_batch_size(size)
      original = Admin::RefereesController::MAX_BULK_USER_CREATIONS
      Admin::RefereesController.send(:remove_const, :MAX_BULK_USER_CREATIONS)
      Admin::RefereesController.const_set(:MAX_BULK_USER_CREATIONS, size)
      yield
    ensure
      Admin::RefereesController.send(:remove_const, :MAX_BULK_USER_CREATIONS)
      Admin::RefereesController.const_set(:MAX_BULK_USER_CREATIONS, original)
    end

    def admin_user
      role_user(1, 0)
    end

    def role_user(group_id, go_id)
      User.create!(
        user_name: "rat_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => group_id, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    def vm_user(club_id)
      User.create!(
        user_name: "vm_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => club_id }],
        teams: []
      )
    end

    def referee_login_user(referee)
      User.create!(
        user_name: "sr_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 6 }],
        referee_id: referee.id,
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
