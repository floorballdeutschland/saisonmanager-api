require 'test_helper'

# Mehrere Freigabeantraege duerfen parallel laufen, Transfers nicht.
#
# Bis hierher galt beides gleich: Ein partieller Unique-Index ueber die vier
# laufenden Status und ein Riegel in #create/#search_player/#direct_assign
# liessen je Spieler genau EINEN laufenden Antrag zu, egal welcher Art. Fuer
# Transfers ist das die Fachregel, fuer Freigaben eine Nebenwirkung -- ein
# Spieler kann fuer mehrere Vereine eine Freigabe brauchen.
#
# Neu gilt: je Spieler ein laufender Transfer, je Spieler UND Zielverein eine
# laufende Freigabe. Ueber Kreuz sperrt nichts; wird ein Transfer vollzogen,
# enden die offenen Freigaben mit ihm (Player#transfer schliesst jede
# Zugehoerigkeit, auch die Zweitspielrechte).
#
# Eigene Datei und nicht im transfer_requests_controller_test: Die Testklasse
# dort steht dicht unter Metrics/ClassLength (Max 1000, siehe
# .rubocop_todo.yml), und ihr setup traegt Konten und Vereine, die diese Faelle
# nicht brauchen.
module Admin
  class ParallelReleaseRequestsTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @sa = create(:state_association, sbk_email: 'sbk@test.example')
      @go = create(:game_operation, state_association_id: @sa.id)
      @former_club = create(:club, game_operation: @go, contact_email: 'abgebend@test.example')
      @requesting_club = create(:club, game_operation: @go, contact_email: 'aufnehmend@test.example')
      @player = create(:player, first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
                                email: 'spieler@test.example',
                                clubs: [{ 'club_id' => @former_club.id, 'home_club' => true }])
      @admin = create(:user, :admin)
      @vm = create(:user, :vm, club_id: @requesting_club.id)
    end

    # Der eigentliche Punkt: Ein Spieler kann fuer mehrere Vereine eine Freigabe
    # brauchen. Vorher sperrte der erste Freigabeantrag jeden weiteren, weil der
    # Riegel die Antragsart nicht ansah.
    test 'zweiter Freigabeantrag auf einen anderen Verein → 201' do
      create_release_request(club: @requesting_club)
      second_club = create_second_requesting_club
      login(@admin)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: second_club.id,
        request_type: 'release'
      }
      assert_response :created
      assert_equal 2, TransferRequest.active_releases.where(player_id: @player.id).count
    end

    # Das Duplikat bleibt gesperrt: add_secondary_club_membership! erkennt die
    # bestehende Mitgliedschaft, der zweite Antrag liefe folgenlos auf approved.
    test 'zweiter Freigabeantrag auf denselben Verein → 422' do
      create_release_request(club: @requesting_club)
      login(@admin)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id,
        request_type: 'release'
      }
      assert_response :unprocessable_entity
      assert_equal 'Fuer diesen Spieler ist bereits ein Freigabeantrag fuer diesen Verein aktiv',
                   JSON.parse(response.body)['error']
      assert_equal 1, TransferRequest.active_releases.where(player_id: @player.id).count
    end

    # Ueber Kreuz sperrt nichts, in beide Richtungen: Die Antragsarten
    # entscheiden Verschiedenes (Heimatverein gegen Zweitspielrecht), und ein
    # vollzogener Transfer beendet die offenen Freigaben von selbst.
    test 'Freigabeantrag trotz laufendem Transferantrag → 201' do
      create_transfer_request(status: 'pending_club')
      second_club = create_second_requesting_club
      login(@admin)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: second_club.id,
        request_type: 'release'
      }
      assert_response :created
    end

    test 'Transferantrag trotz laufender Freigabe → 201' do
      create_release_request(club: create_second_requesting_club)
      login(@vm)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
      assert_equal 'transfer', JSON.parse(response.body)['request_type']
    end

    # Ein laufender Transfer sperrt nur die naechste Antragsart, nicht die
    # Suche: Die Maske waehlt die Art erst am gefundenen Spieler, sie braucht
    # den Treffer also auch dann, wenn nur noch die Freigabe moeglich ist.
    test 'search_player liefert den Treffer mit der gesperrten Antragsart' do
      create_transfer_request(status: 'pending_club')
      login(@admin)
      search_player(@requesting_club.id)
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @player.id, body.dig('player', 'id')
      assert_equal ['transfer'], body['blocked_request_types']
    end

    test 'search_player ohne laufenden Antrag sperrt keine Antragsart' do
      login(@admin)
      search_player(@requesting_club.id)
      assert_response :success
      assert_empty JSON.parse(response.body)['blocked_request_types']
    end

    # Nur wenn keine der beiden Arten mehr moeglich ist, weist die Suche ab --
    # dann nimmt sie #create nichts vorweg.
    test 'search_player weist ab, wenn beide Antragsarten gesperrt sind' do
      create_transfer_request(status: 'pending_club')
      create_release_request(club: @requesting_club)
      login(@admin)
      search_player(@requesting_club.id)
      assert_response :unprocessable_entity
      assert_match(/Transferantrag aktiv/, JSON.parse(response.body)['error'])
    end

    # Ein Vereinswechsel schliesst JEDE bestehende Zugehoerigkeit, auch die
    # Zweitspielrechte (Player#transfer). Ein danach noch offener Freigabeantrag
    # wuerde vom alten Heimatverein und dessen LV genehmigt, also von einer
    # Stelle, die den Spieler nicht mehr hat.
    test 'Vollzug eines Transfers annulliert die offenen Freigabeantraege' do
      release = create_release_request(club: create_second_requesting_club)
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      assert_equal 'approved', tr.reload.status
      assert_equal 'withdrawn', release.reload.status
      assert_equal @admin.id, release.withdrawn_by
      assert_not_nil release.withdrawn_at
      assert_nil release.player_confirmation_token,
                 'der Bestaetigungslink des beendeten Antrags darf nicht weiter gelten'
    end

    test 'der annullierte Freigabeantrag wird gemeldet' do
      create_release_request(club: create_second_requesting_club)
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      perform_enqueued_jobs do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :success
      subjects = ActionMailer::Base.deliveries.map(&:subject)
      assert(subjects.any? { |subject| subject.include?('Spielerfreigabe-Antrag beendet, Spieler transferiert') },
             "keine Mail zum beendeten Freigabeantrag, verschickt wurden: #{subjects.inspect}")
    end

    # Eine bereits erteilte Freigabe ist kein laufender Antrag mehr: Sie bleibt
    # `approved` stehen und ist die Chronik des Vorgangs. Entzogen wird sie ueber
    # die geschlossene Mitgliedschaft (Player#transfer) und die Mail an den
    # Zweitverein (#secondary_club_notification).
    test 'eine erteilte Freigabe wird durch den Transfer nicht annulliert' do
      release = create_release_request(club: create_second_requesting_club, status: 'approved')
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      assert_equal 'approved', release.reload.status
    end

    # Die Direktzuweisung ist selbst ein Transfer: Laufende Freigaben halten sie
    # nicht auf, sie enden mit dem Vollzug.
    test 'Direktzuweisung trotz laufender Freigabe → 201' do
      release = create_release_request(club: create_second_requesting_club)
      login(@admin)
      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
      assert_equal 'withdrawn', release.reload.status
    end

    # Der Riegel liegt nicht nur im Controller: Die beiden partiellen
    # Unique-Indizes sind der eigentliche Waechter (der Controller prueft und
    # schreibt nicht atomar). Ohne diesen Test kaeme ein falsches
    # `where`-Praedikat oder ein vergessenes `unique: true` durch alle
    # Controller-Faelle, weil die alle am Riegel davor haengen bleiben.
    test 'die Datenbank laesst keine zweite laufende Freigabe auf denselben Verein zu' do
      create_release_request(club: @requesting_club)

      assert_raises ActiveRecord::RecordNotUnique do
        TransferRequest.create!(
          player: @player, requesting_club: @requesting_club, former_club: @former_club,
          status: 'pending_lv', created_by: @vm.id, season_id: 18, request_type: 'release'
        )
      end
    end

    test 'die Datenbank laesst keinen zweiten laufenden Transfer zu' do
      create_transfer_request(status: 'pending_club')

      assert_raises ActiveRecord::RecordNotUnique do
        TransferRequest.create!(
          player: @player, requesting_club: create_second_requesting_club,
          former_club: @former_club, status: 'pending_lv', created_by: @vm.id,
          season_id: 18, request_type: 'transfer'
        )
      end
    end

    test 'die Datenbank laesst Freigaben auf verschiedene Vereine zu' do
      create_release_request(club: @requesting_club)

      assert_nothing_raised do
        create_release_request(club: create_second_requesting_club)
      end
    end

    # Der geplante Transfer wird nicht in #approve_lv vollzogen, sondern erst
    # spaeter in #execute. Ohne diesen Fall bliebe ein Ausfall der Annullierung
    # auf diesem Weg gruen.
    test 'der Vollzug eines geplanten Transfers annulliert die offenen Freigaben' do
      release = create_release_request(club: create_second_requesting_club)
      tr = create_transfer_request(status: 'scheduled')
      tr.update!(effective_date: Date.today - 1, approved_by_lv_user_id: @admin.id,
                 lv_approved_at: Time.current)
      login(@admin)

      patch "/api/v2/admin/transfer_requests/#{tr.id}/execute"

      assert_response :success
      assert_equal 'approved', tr.reload.status
      assert_equal 'withdrawn', release.reload.status
      assert_equal @admin.id, release.withdrawn_by
    end

    # Freigabe und Transfer auf DENSELBEN Verein: Die Freigabe wird mit dem
    # Vollzug gegenstandslos, weil die Zugehoerigkeit ohnehin entsteht -- nur
    # als Heimat statt als Zweitspielrecht.
    test 'die Freigabe auf den Zielverein des Transfers wird ebenfalls annulliert' do
      release = create_release_request(club: @requesting_club)
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)

      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"

      assert_response :success
      assert_equal 'withdrawn', release.reload.status
      assert_equal @requesting_club.id, @player.reload.home_club_entry['club_id']
    end

    # ---------------------------------------------------------------------------
    # Transfersperrfrist: dieselbe Auskunft in Suche und Antrag
    # ---------------------------------------------------------------------------

    # Die Sperrfrist stand nur in #create. Die Suche meldete „nichts gesperrt",
    # die Maske bot den Transfer an, und die Absage kam erst nach dem
    # Ausfuellen -- genau das, was die Auskunft der Suche vermeiden soll.
    test 'search_player meldet die Transfersperrfrist als gesperrten Transfer' do
      Transfer.create!(player_id: @player.id, former_club_id: create_second_requesting_club.id,
                       new_club_id: @former_club.id, created_by: @admin.id, season_id: 18)
      login(@admin)

      search_player(@requesting_club.id)

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal ['transfer'], body['blocked_request_types']
      assert_match(/Transfersperrfrist/, body.dig('blocked_request_reasons', 'transfer'))
    end

    test 'Transferantrag innerhalb der Sperrfrist wird abgewiesen' do
      Transfer.create!(player_id: @player.id, former_club_id: create_second_requesting_club.id,
                       new_club_id: @former_club.id, created_by: @admin.id, season_id: 18)
      login(@vm)

      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }

      assert_response :unprocessable_entity
      assert_match(/Transfersperrfrist/, JSON.parse(response.body)['error'])
    end

    # Die Freigabe ist von der Sperrfrist ausdruecklich nicht betroffen: Sie
    # aendert den Heimatverein nicht.
    test 'Freigabeantrag innerhalb der Transfersperrfrist ist moeglich' do
      Transfer.create!(player_id: @player.id, former_club_id: create_second_requesting_club.id,
                       new_club_id: @former_club.id, created_by: @admin.id, season_id: 18)
      login(@vm)

      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id,
        request_type: 'release'
      }

      assert_response :created
    end

    # Der Antragstyp traegt seit der Aufteilung die Eindeutigkeit: Ein dritter
    # Wert faellt aus beiden Indizes und aus dem Riegel heraus.
    test 'ein unbekannter Antragstyp wird nicht gespeichert' do
      tr = TransferRequest.new(
        player: @player, requesting_club: @requesting_club, former_club: @former_club,
        status: 'pending_club', created_by: @vm.id, season_id: 18, request_type: 'Release'
      )

      assert_not tr.valid?
      assert_includes tr.errors.attribute_names, :request_type
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def create_second_requesting_club
      create(:club, game_operation: @go, contact_email: 'zweiter@test.example')
    end

    def create_release_request(club:, status: 'pending_club')
      TransferRequest.create!(
        player: @player, requesting_club: club, former_club: @former_club,
        status: status, created_by: @vm.id, season_id: 18, request_type: 'release'
      )
    end

    def create_transfer_request(status:)
      TransferRequest.create!(
        player: @player, requesting_club: @requesting_club, former_club: @former_club,
        status: status, created_by: @vm.id, season_id: 18, request_type: 'transfer'
      )
    end

    def search_player(requesting_club_id)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: requesting_club_id
      }
    end
  end
end
