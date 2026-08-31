require 'test_helper'
require_relative 'transfer_request_test_helpers'

module Admin
  class TransferRequestsControllerTest < ActionDispatch::IntegrationTest
    include TransferRequestTestHelpers

    setup do
      # StateAssociation mit sbk_email – nötig damit pending_lv_notification
      # verschickt wird (mailer hat early return wenn sbk_email fehlt).
      @state_association = StateAssociation.create!(
        name: "LV Test #{SecureRandom.hex(4)}",
        short_name: "LV#{SecureRandom.hex(2)}",
        sbk_email: 'sbk@test.example.com'
      )

      @game_operation = GameOperation.create!(
        name: "SBK Test #{SecureRandom.hex(4)}",
        short_name: "ST#{SecureRandom.hex(2)}",
        state_association: @state_association
      )

      # contact_email auf Clubs setzen – sonst geben rejected_notification und
      # player_rejected_clubs_notification 0 Mails ab (early return im Mailer).
      @former_club = Club.create!(
        name: "Abgebender Verein #{SecureRandom.hex(4)}",
        short_name: "AV#{SecureRandom.hex(1)}",
        contact_email: 'former@test.example.com',
        state_association: @state_association
      )

      @requesting_club = Club.create!(
        name: "Aufnehmender Verein #{SecureRandom.hex(4)}",
        short_name: "AU#{SecureRandom.hex(1)}",
        contact_email: 'requesting@test.example.com',
        state_association: @state_association
      )

      create(:setting, current_season_id: '18')

      @player = Player.create!(
        first_name: 'Max',
        last_name: 'Mustermann',
        birthdate: '1995-03-15',
        nation_id: '1',
        gender: 'm',
        email: 'max.mustermann@example.com',
        clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }],
        licenses: []
      )

      # Verein außerhalb des Test-Spielbetriebs, für den nur die VM-Rolle greift.
      @vm_only_club = Club.create!(
        name: "Nur-VM Verein #{SecureRandom.hex(4)}",
        short_name: "NV#{SecureRandom.hex(1)}"
      )

      @vm_requesting = create_user(user_group_id: 4, club_id: @requesting_club.id)
      @vm_former     = create_user(user_group_id: 4, club_id: @former_club.id)
      @sbk           = create_user_sbk(game_operation_id: @game_operation.id)
      @admin         = create_user(user_group_id: 1, game_operation_id: 0)
      @tm            = create_user(user_group_id: 5, game_operation_id: 0)
      # Mehrfachrolle wie im gemeldeten Fall: SBK eines Verbands und zugleich
      # VM eines Vereins, der nicht der aufnehmende Verein ist.
      @sbk_and_vm = create_user_sbk_and_vm(
        game_operation_id: @game_operation.id,
        club_id: @vm_only_club.id
      )
    end

    # ---------------------------------------------------------------------------
    # GET /api/v2/admin/transfer_requests/search_player
    # ---------------------------------------------------------------------------

    test 'search_player findet Spieler über ISO-Geburtsdatum' do
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    test 'search_player lehnt nicht-ISO-Geburtsdatum mit 422 ab' do
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '15.03.1995'
      }
      assert_response :unprocessable_entity
      assert_match(/JJJJ-MM-TT/, JSON.parse(response.body)['error'])
    end

    test 'search_player findet zusammengefuehrte Dubletten nicht' do
      master = create(:player, first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-16')
      @player.merge_into!(master, @admin.id)
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_nil JSON.parse(response.body)['player']
    end

    # Wer aus der Liste des abgebenden Vereins genommen wurde, muss fuer den
    # aufnehmenden auffindbar bleiben – sonst ist der Vereinsaustritt eine Sackgasse
    # (api#472).
    test 'search_player findet deaktivierte Spieler' do
      @player.deactivate!(@admin.id, reason: 'Vereinsaustritt')
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # api#496: Altbestand mit einem Leerzeichen am Namensende (vor der
    # Player#strip_names-Sicherung entstanden, hier per update_column simuliert,
    # da save den Namen sonst schon vor dem Test trimmen würde) muss weiterhin als
    # exakter Treffer gelten.
    test 'search_player findet Spieler mit Leerzeichen am Namensende im Bestand' do
      @player.update_column(:first_name, 'Max ')
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Postgres TRIM() kennt nur das Leerzeichen; ein Tabulator aus einem
    # CSV-/Excel-Import bliebe damit unauffindbar (Player::SQL_NAME_PADDING).
    test 'search_player findet Spieler mit Tabulator am Namensende im Bestand' do
      @player.update_column(:last_name, "Mustermann\t")
      login(@admin)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    test 'reiner VM darf nicht für fremden Verein suchen → 403' do
      login(@vm_requesting)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @vm_only_club.id
      }
      assert_response :forbidden
    end

    # Mehrfachrollen: die VM-Vereinsbindung darf die stärkere SBK-Rolle nicht
    # verdecken. Vorher brach search_player mit 403 ab, bevor der Direkt-
    # Transfer überhaupt erreicht wurde.
    test 'SBK mit zusätzlicher VM-Rolle darf für Verein im eigenen Spielbetrieb suchen' do
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Der gemeldete Fall: SBK Niedersachsen und zugleich VM eines Vereins gibt
    # einen Spieler ihres Spielbetriebs an einen Verein in einem anderen
    # Landesverband ab. Zuständig ist der abgebende Verband, also sie selbst --
    # `#direct_assign` hätte den Vorgang zugelassen, die Suche davor brach mit
    # 403 ab und ließ sie nie bis dorthin kommen.
    #
    # `create_club_in_other_game_operation` und nicht ein Verein ohne
    # Landesverband: Ein fehlender Spielbetrieb ist `nil` und damit ein anderer
    # Eingabewert für `ph[:sbk].include?` als eine fremde Spielbetriebs-ID. Nur
    # der zweite ist der gemeldete Fall.
    test 'SBK mit zusätzlicher VM-Rolle darf für Verein eines anderen Landesverbands suchen, wenn der abgebende Verein im eigenen Spielbetrieb liegt' do
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Der ganze gemeldete Weg an einem Stück: erst suchen, dann zuweisen, beides
    # LV-übergreifend mit Doppelrolle. Die beiden Schritte einzeln zu prüfen war
    # genau die Lücke -- der Fehler bestand darin, dass sie auseinander liefen.
    test 'SBK mit zusätzlicher VM-Rolle: Suche und Direktzuweisung in einen anderen Landesverband' do
      other_club = create_club_in_other_game_operation
      login(@sbk_and_vm)

      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: other_club.id
      }
      assert_response :success

      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: JSON.parse(response.body).dig('player', 'id'),
        requesting_club_id: other_club.id
      }
      assert_response :created
      assert_equal 'approved', JSON.parse(response.body)['status']
      assert_equal other_club.id, @player.reload.home_club_entry['club_id']
    end

    # Gegenprobe: Liegt weder der abgebende noch der aufnehmende Verein im
    # eigenen Spielbetrieb, bleibt es bei der Absage. Sonst wäre die
    # Vereinsbindung der VM-Rolle für jede SBK-Doppelrolle aufgehoben. Zwei
    # verschiedene fremde Vereine, damit die Absage nicht auch aus „Spieler ist
    # bereits in diesem Verein" kommen könnte.
    test 'SBK mit zusätzlicher VM-Rolle darf nicht suchen, wenn auch der abgebende Verein außerhalb liegt → 403' do
      foreign_home_club = create_club_in_other_game_operation
      foreign_player = Player.create!(
        first_name: 'Erika',
        last_name: 'Fremdverband',
        birthdate: '1996-07-21',
        nation_id: '1',
        gender: 'w',
        email: 'erika.fremdverband@example.com',
        clubs: [{ 'club_id' => foreign_home_club.id, 'home_club' => true, 'valid_until' => nil }],
        licenses: []
      )
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: foreign_player.first_name, last_name: foreign_player.last_name,
        birthdate: '1996-07-21', requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :forbidden
    end

    # Ein Verein ohne zuständigen Landesverband hat `main_game_operation_id` nil
    # und liegt damit in keinem Spielbetrieb. Er bleibt für die Doppelrolle
    # gesperrt, solange der abgebende Verein nicht ihr eigener ist. Eigener Test,
    # weil `nil` ein anderer Eingabewert ist als eine fremde Spielbetriebs-ID.
    test 'SBK mit zusätzlicher VM-Rolle darf nicht suchen, wenn der abgebende Verein keinen Spielbetrieb hat → 403' do
      # Mit Kontaktadresse, damit der Test auf dem Rechtezweig bleibt: Seit
      # api#581 weist die Suche einen abgebenden Verein ohne Postfach und ohne
      # Vereinsmanager vorher als Datenproblem ab (422), und die Rechteprüfung
      # käme gar nicht mehr dran.
      homeless_club = Club.create!(
        name: "Verein ohne LV #{SecureRandom.hex(4)}",
        short_name: "OL#{SecureRandom.hex(1)}",
        contact_email: 'ohne-lv@test.example.com'
      )
      homeless_player = Player.create!(
        first_name: 'Nils',
        last_name: 'Verbandslos',
        birthdate: '1994-02-02',
        nation_id: '1',
        gender: 'm',
        email: 'nils.verbandslos@example.com',
        clubs: [{ 'club_id' => homeless_club.id, 'home_club' => true, 'valid_until' => nil }],
        licenses: []
      )
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: homeless_player.first_name, last_name: homeless_player.last_name,
        birthdate: '1994-02-02', requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :forbidden
    end

    # Der aufnehmende Verein im eigenen Spielbetrieb bleibt für sich genommen
    # ein Grund: Eine SBK soll für einen Verein ihres Verbands auch dann
    # arbeiten können, wenn der Spieler von außerhalb kommt.
    test 'SBK mit zusätzlicher VM-Rolle darf für eigenen Verein suchen, wenn der Spieler von außerhalb kommt' do
      incoming_player = Player.create!(
        first_name: 'Jonas',
        last_name: 'Zuzug',
        birthdate: '1999-01-09',
        nation_id: '1',
        gender: 'm',
        email: 'jonas.zuzug@example.com',
        clubs: [{ 'club_id' => create_club_in_other_game_operation.id, 'home_club' => true, 'valid_until' => nil }],
        licenses: []
      )
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: incoming_player.first_name, last_name: incoming_player.last_name,
        birthdate: '1999-01-09', requesting_club_id: @requesting_club.id
      }
      assert_response :success
      assert_equal incoming_player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Ohne offenen Heimat-Eintrag gibt es keinen abgebenden Verein und damit
    # keine Zuständigkeit, an der sich eine Rechtefrage entscheiden ließe. Die
    # Suche muss das Datenproblem benennen und darf es nicht als Rechteproblem
    # ausgeben, sonst sucht die zuständige Person den Fehler bei ihrer Rolle.
    # Derselbe Wortlaut wie in #create und #direct_assign.
    test 'Spieler ohne aktiven Heimatverein meldet das Datenproblem, nicht fehlende Rechte → 422' do
      @player.update!(clubs: [{ 'club_id' => @former_club.id, 'home_club' => true,
                               'valid_until' => 1.day.ago.iso8601 }])
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :unprocessable_entity
      assert_equal 'Spieler hat keinen aktiven Heimverein', JSON.parse(response.body)['error']
    end

    # Zeigt der Heimat-Eintrag auf einen gelöschten Verein, ist das ebenfalls ein
    # Datenfehler und keine Rechtefrage. Kein 500.
    test 'Heimat-Eintrag ohne auffindbaren Verein meldet den Datenfehler → 404' do
      @player.update!(clubs: [{ 'club_id' => 999_999, 'home_club' => true, 'valid_until' => nil }])
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :not_found
      assert_equal 'Abgebender Verein nicht gefunden', JSON.parse(response.body)['error']
    end

    # api#581: Dieselbe Auskunft wie in #create. Sonst meldet die Suche einen
    # Treffer und der Antrag fällt gleich danach auf 422 -- dasselbe Nachziehen
    # wie beim deaktivierten aufnehmenden Verein (api#512).
    test 'search_player weist abgebenden Verein ohne Postfach und ohne Vereinsmanager ab → 422' do
      make_former_club_unreachable
      login(@vm_requesting)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
      assert_match(/weder eine Vereins-E-Mailadresse/, JSON.parse(response.body)['error'])
    end

    # Die Rückfallebene, die die Meldung selbst nennt: Die Suche ist der einzige
    # Weg, auf dem die Direktzuweisungs-Maske ihren Spieler findet
    # (transfer-request-direct.component.ts bricht ohne `foundPlayer` ab). Wies
    # sie auch die SBK ab, war aus der 14-Tage-Verzögerung eine Sackgasse
    # geworden: Die Vereinsmanagerin wird an die SBK verwiesen, und die kam über
    # die Maske nicht weiter.
    test 'search_player laesst die SBK auch bei unerreichbarem abgebenden Verein durch' do
      make_former_club_unreachable
      login(@sbk)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Der ganze Ausweg an einem Stück, wie in api#561: Die beiden Schritte
    # einzeln zu prüfen war dort genau die Lücke.
    test 'SBK: Suche und Direktzuweisung bei unerreichbarem abgebenden Verein' do
      make_former_club_unreachable
      login(@sbk)

      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :success

      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: JSON.parse(response.body).dig('player', 'id'),
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
      assert_equal 'approved', JSON.parse(response.body)['status']
    end

    # Der Admin genehmigt in approve_club selbst, für ihn strandet der Antrag
    # also nicht. Ihn abzuweisen hieß, die stärkere Rolle schlechter zu stellen
    # als die schwächere und sie an eine SBK zu verweisen, die approve_club
    # gar nicht darf.
    test 'Admin darf trotz unerreichbaren abgebenden Vereins anlegen → 201' do
      make_former_club_unreachable
      login(@admin)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
    end

    # Zwei Adressen mit Semikolon in einem Feld, das als EINE Adresse verschickt
    # wird: Auf Produktion vorhanden (siehe Club::EMAIL_FORMAT), und niemand hat
    # je etwas bekommen. Genau der Zustand aus #581, nur mit gefülltem Feld --
    # eine Prüfung auf `present?` hätte ihn durchgelassen.
    test 'Antrag an abgebenden Verein mit unzustellbarer Sammeladresse → 422' do
      @former_club.update_column(:contact_email, 'a@test.example.com;b@test.example.com')
      @vm_former.update!(permissions: [])
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
      assert_match(/weder eine Vereins-E-Mailadresse/, JSON.parse(response.body)['error'])
    end

    # Reihenfolge der Absagen: Ein laufender Antrag ist der nähere Grund. Stand
    # die Stammdaten-Auskunft davor, ging die beantragende Person wegen der
    # Stammdaten zur SBK, obwohl ihr Antrag längst lief.
    test 'laufender Antrag wird vor den fehlenden Stammdaten gemeldet' do
      create_transfer_request(status: 'pending_club')
      make_former_club_unreachable
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
      assert_equal 'Fuer diesen Spieler ist bereits ein Transferantrag aktiv',
                   JSON.parse(response.body)['error']
    end

    # Die Meldung nennt den abgebenden Verein beim Namen. Stand sie vor der
    # Rechteprüfung, erfuhr die Vereinsmanagerin eines fremden Vereins damit den
    # Heimatverein einer beliebigen Person.
    test 'fremder Vereinsmanager bekommt 403 und nicht den Namen des abgebenden Vereins' do
      make_former_club_unreachable
      other_club = create_club_in_other_game_operation
      login(@vm_requesting)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: other_club.id
      }
      assert_response :forbidden
      assert_no_match(/#{Regexp.escape(@former_club.name)}/, response.body)
    end

    # Bestandsanträge aus der Zeit vor dem Riegel müssen auflösbar bleiben:
    # Steckte die Prüfung in einem gemeinsamen before_action oder in
    # find_transfer_request, wären sie stumm eingesperrt und blockierten über
    # den active-Guard bis zum Fristablauf.
    test 'ein bestehender Antrag bleibt trotz unerreichbaren Vereins annullierbar' do
      tr = create_transfer_request(status: 'pending_club')
      make_former_club_unreachable
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/cancel"
      assert_response :success
      assert_equal 'withdrawn', tr.reload.status
    end

    test 'ein bestehender Antrag bleibt trotz unerreichbaren Vereins genehmigungsfaehig' do
      tr = create_transfer_request(status: 'pending_club')
      make_former_club_unreachable
      login(@admin)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :success
      assert_equal 'pending_player', tr.reload.status
    end

    # Ohne Zielverein ist die Frage „darf sie für diesen Verein handeln" nicht zu
    # stellen; entschieden wird dann allein über den abgebenden Verein. Die
    # Maske schickt immer einen Verein mit (transfer-request.service.ts), der
    # Fall ist also nur über einen Direktaufruf erreichbar. Festgehalten, weil
    # die Antwort sich mit dieser Änderung von 403 auf 200 verschiebt.
    test 'SBK mit zusätzlicher VM-Rolle darf ohne Zielverein suchen, wenn der abgebende Verein im eigenen Spielbetrieb liegt' do
      login(@sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15'
      }
      assert_response :success
      assert_equal @player.id, JSON.parse(response.body).dig('player', 'id')
    end

    # Die beiden übrigen Zweige der Rechteprüfung sind nur mit einer VM-Rolle
    # daneben überhaupt erreichbar, weil die Prüfung sonst gar nicht erst läuft.
    # Bundesweiter Scope (FD) und Administration dürfen verbandsübergreifend,
    # unabhängig davon, wo abgebender und aufnehmender Verein liegen.
    test 'bundesweit gescopte SBK mit VM-Rolle darf für jeden Verein suchen' do
      global_sbk_and_vm = create_user_sbk_and_vm(game_operation_id: 0, club_id: @vm_only_club.id)
      login(global_sbk_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :success
    end

    test 'Administration mit VM-Rolle darf für jeden Verein suchen' do
      admin_and_vm = create_user(user_group_id: 1, game_operation_id: 0, club_id: @vm_only_club.id)
      admin_and_vm.update!(permissions: admin_and_vm.permissions + [{ 'user_group_id' => 4, 'club_id' => @vm_only_club.id.to_s }])
      login(admin_and_vm)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: create_club_in_other_game_operation.id
      }
      assert_response :success
    end

    test 'SBK mit zusätzlicher VM-Rolle führt Direkt-Transfer durch → 201' do
      login(@sbk_and_vm)
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests/direct_assign', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'approved', body['status']
      assert_equal true, body['direct']

      home_club = @player.reload.clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }
      assert_equal @requesting_club.id, home_club['club_id']
    end

    # Direkt-Transfer darf nur davon abhängen, ob der Nutzer für den ABGEBENDEN
    # Verein zuständig ist (analog #lv_authorized? im mehrstufigen Prozess) –
    # der aufnehmende Verein kann in jedem anderen Landesverband liegen.
    test 'SBK des abgebenden Vereins darf Direkt-Transfer in anderen Landesverband durchführen → 201' do
      other_club = create_club_in_other_game_operation

      login(@sbk) # @sbk ist nur für @game_operation (LV des abgebenden Vereins) zuständig
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests/direct_assign', params: {
          player_id: @player.id,
          requesting_club_id: other_club.id
        }
      end
      assert_response :created
    end

    # Die Vereinsauswahl der Maske bietet nur aktive Vereine an; ein direkter
    # Aufruf soll deshalb nicht in einem deaktivierten Verein landen. Der
    # ABGEBENDE Verein darf dagegen deaktiviert sein -- ein aufgelöster Verein
    # gibt seine Spieler ja gerade ab.
    test 'Direkt-Transfer in einen deaktivierten Verein → 422' do
      @requesting_club.update!(deactivated_at: Time.current)

      login(@sbk)
      assert_no_emails do
        post '/api/v2/admin/transfer_requests/direct_assign', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :unprocessable_entity
      assert_equal 0, TransferRequest.where(player_id: @player.id).count
    end

    test 'Direkt-Transfer aus einem deaktivierten abgebenden Verein → 201' do
      @former_club.update!(deactivated_at: Time.current)

      login(@sbk)
      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
    end

    test 'SBK ohne Zugriff auf den abgebenden Verein darf Direkt-Transfer nicht durchführen → 403' do
      other_club = create_club_in_other_game_operation
      other_sbk = create_user_sbk(game_operation_id: other_club.main_game_operation_id)

      login(other_sbk)
      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: @player.id,
        requesting_club_id: other_club.id
      }
      assert_response :forbidden
    end

    # ---------------------------------------------------------------------------
    # POST /api/v2/admin/transfer_requests
    # ---------------------------------------------------------------------------

    test 'VM erstellt Transferantrag → 201, Status pending_club' do
      login(@vm_requesting)
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'pending_club', body['status']
      assert_equal @player.id, body['player']['id']
    end

    test 'Antrag für zusammengefuehrte Dublette wird abgelehnt → 422' do
      master = create(:player, first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-16')
      @player.merge_into!(master, @admin.id)
      login(@vm_requesting)
      assert_no_emails do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :unprocessable_entity
      assert_match(/zusammengeführt/, JSON.parse(response.body)['error'])
    end

    # Die Kennzeichnung des abgebenden Vereins ist kein Transferhindernis, und der
    # Transfer raeumt sie ab: sonst waere die Person im aufnehmenden Verein sofort
    # wieder aus der aktiven Liste verschwunden (api#472).
    test 'Antrag für deaktivierten Spieler ist möglich' do
      @player.deactivate!(@admin.id, reason: 'Vereinsaustritt')
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
    end

    # api#512: Der mehrstufige Prozess prüfte den aufnehmenden Verein an keiner
    # Stelle, während die Direktzuweisung ihn seit api#511 abweist. Geprüft wird
    # jetzt beim Anlegen, beim Genehmigen und beim Vollziehen, weil zwischen
    # Antrag und Vollzug Tage liegen.
    test 'Antrag in einen deaktivierten aufnehmenden Verein → 422' do
      @requesting_club.update!(deactivated_at: Time.current)
      login(@vm_requesting)
      assert_no_emails do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :unprocessable_entity
      assert_equal 0, TransferRequest.where(player_id: @player.id).count
    end

    # Gegenrichtung, eigene Prüfung in #create: Ein aufgelöster Verein gibt seine
    # Spieler gerade ab, der Antrag muss also durchgehen.
    test 'Antrag aus einem deaktivierten abgebenden Verein → 201' do
      @former_club.update!(deactivated_at: Time.current)
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
    end

    # api#581: Hat der abgebende Verein weder Postfach noch Vereinsmanager, hat
    # die erste Mail des Verfahrens keinen Empfänger und niemand außer einem
    # Admin könnte den Antrag genehmigen. Er bliebe 14 Tage in pending_club
    # liegen und sperrte über den active-Guard jeden weiteren Antrag desselben
    # Spielers, auch den auf einen anderen Verein.
    test 'Antrag an abgebenden Verein ohne Postfach und ohne Vereinsmanager → 422' do
      make_former_club_unreachable
      login(@vm_requesting)
      assert_no_emails do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :unprocessable_entity
      error = JSON.parse(response.body)['error']
      assert_match(/weder eine Vereins-E-Mailadresse/, error)
      # Der Verein wird beim Namen genannt, damit klar ist, wessen Stammdaten fehlen.
      assert_match(/#{Regexp.escape(@former_club.name)}/, error)
      assert_equal 0, TransferRequest.where(player_id: @player.id).count
    end

    # Eines von beiden genügt: Die Mail kommt an, und der Verein kann sich um
    # einen Zugang oder um die zuständige SBK kümmern.
    test 'Antrag an abgebenden Verein mit Kontaktadresse, aber ohne Vereinsmanager → 201' do
      @vm_former.update!(permissions: [])
      login(@vm_requesting)
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
    end

    # Umgekehrt ebenso: Ohne Kontaktadresse geht die Mail an die persönliche
    # Adresse des Vereinsmanagers, und er kann den Antrag genehmigen.
    test 'Antrag an abgebenden Verein mit Vereinsmanager, aber ohne Kontaktadresse → 201' do
      @former_club.update!(contact_email: nil)
      @vm_former.update!(email: 'vm.former@test.example.com')
      login(@vm_requesting)
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
    end

    # Die Abwahl aus der Vereinspost entscheidet über den Verteiler, nicht über
    # die Rolle: Der Vereinsmanager sieht den Antrag in seiner Übersicht und kann
    # ihn genehmigen. Der Antrag geht deshalb durch, auch wenn keine Mail rausgeht.
    test 'abgewaehlter Vereinsmanager reicht als Bearbeiter → 201' do
      @former_club.update!(contact_email: nil, notify_user_ids: [])
      login(@vm_requesting)
      assert_no_emails do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
    end

    # Gleiche Regel wie in search_player, sonst meldet die Suche einen Treffer
    # und der Antrag fällt gleich danach auf 403 -- dieselbe Falle wie beim
    # deaktivierten aufnehmenden Verein in api#512.
    test 'SBK mit zusätzlicher VM-Rolle darf Antrag für Verein eines anderen Landesverbands stellen' do
      other_club = create_club_in_other_game_operation
      login(@sbk_and_vm)

      # Erst suchen, dann beantragen: Genau diese Kopplung war der Fehler, die
      # Suche meldete einen Treffer und der Antrag fiel danach durch.
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: other_club.id
      }
      assert_response :success

      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: other_club.id
      }
      assert_response :created
    end

    test 'VM kann keinen Antrag für fremden Verein erstellen → 403' do
      other_club = Club.create!(
        name: "Fremder Verein #{SecureRandom.hex(4)}",
        short_name: "FR#{SecureRandom.hex(1)}"
      )
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: other_club.id
      }
      assert_response :forbidden
    end

    test 'Nicht-VM (TM) kann keinen Transferantrag erstellen → 403' do
      login(@tm)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :forbidden
    end

    test 'Spieler ohne E-Mail kann nicht beantragt werden → 422' do
      @player.update_columns(email: nil)
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
    end

    test 'Zweiter aktiver Antrag für denselben Spieler → 422' do
      existing = TransferRequest.create!(
        player: @player,
        requesting_club: @requesting_club,
        former_club: @former_club,
        status: 'pending_club',
        created_by: @vm_requesting.id,
        season_id: 18
      )
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
    ensure
      existing&.destroy
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/approve_club
    # ---------------------------------------------------------------------------

    test 'VM des abgebenden Vereins genehmigt → Status pending_player, Spieler-Mail wird versendet' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'pending_player', body['status']
      assert_equal 'pending_player', tr.reload.status
      assert tr.reload.player_confirmation_token.present?
    end

    test 'VM des aufnehmenden Vereins darf approve_club nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_requesting)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :forbidden
    end

    test 'approve_club bei falschem Status → 422' do
      tr = create_transfer_request(status: 'pending_player')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :unprocessable_entity
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/reject_club
    # ---------------------------------------------------------------------------

    test 'VM lehnt ab → Status rejected_by_club' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_club",
              params: { rejection_reason: 'Spieler wird noch benötigt' }
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'rejected_by_club', body['status']
      assert_equal 'rejected_by_club', tr.reload.status
    end

    test 'reject_club ohne Begründung → 422' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_club"
      assert_response :unprocessable_entity
    end

    # ---------------------------------------------------------------------------
    # GET /api/v2/admin/transfer_requests/player_approve?token=X (kein Auth)
    # ---------------------------------------------------------------------------

    test 'Spieler bestätigt via Token → 302 Redirect, Status pending_lv' do
      tr = create_transfer_request(status: 'pending_player')
      token = tr.player_confirmation_token
      assert_emails 2 do
        get "/api/v2/admin/transfer_requests/player_approve", params: { token: token }
      end
      assert_response :redirect
      assert_match 'result=approved', response.location
      assert_equal 'pending_lv', tr.reload.status
    end

    test 'player_approve mit ungültigem Token → 302 Redirect mit result=error' do
      get '/api/v2/admin/transfer_requests/player_approve', params: { token: 'ungueltig' }
      assert_response :redirect
      assert_match 'result=error', response.location
    end

    test 'player_approve bei bereits genehmigtem Antrag → 302 Redirect mit already_approved' do
      tr = create_transfer_request(status: 'pending_lv')
      token = tr.player_confirmation_token
      get '/api/v2/admin/transfer_requests/player_approve', params: { token: token }
      assert_response :redirect
      assert_match 'already_approved', response.location
    end

    # ---------------------------------------------------------------------------
    # GET /api/v2/admin/transfer_requests/player_reject?token=X (kein Auth)
    # ---------------------------------------------------------------------------

    test 'Spieler lehnt via Token ab → 302 Redirect, Status rejected_by_player' do
      tr = create_transfer_request(status: 'pending_player')
      token = tr.player_confirmation_token
      assert_emails 1 do
        get '/api/v2/admin/transfer_requests/player_reject', params: { token: token }
      end
      assert_response :redirect
      assert_match 'result=rejected', response.location
      assert_equal 'rejected_by_player', tr.reload.status
    end

    test 'player_reject mit ungültigem Token → 302 Redirect mit result=error' do
      get '/api/v2/admin/transfer_requests/player_reject', params: { token: 'ungueltig' }
      assert_response :redirect
      assert_match 'result=error', response.location
    end

    test 'player_reject bei bereits abgelehntem Antrag → 302 Redirect mit already_rejected' do
      tr = create_transfer_request(status: 'rejected_by_player')
      # Token wird bei rejected_by_player auf nil gesetzt; neuen erzeugen für Lookup-Test
      tr.update_columns(player_confirmation_token: 'dummy_already_rejected')
      get '/api/v2/admin/transfer_requests/player_reject',
          params: { token: 'dummy_already_rejected' }
      assert_response :redirect
      assert_match 'already_rejected', response.location
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/approve_lv
    # ---------------------------------------------------------------------------

    test 'SBK genehmigt LV → Status approved (sofortiger Transfer)' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'approved', body['status']
      assert_equal 'approved', tr.reload.status
    end

    test 'Admin genehmigt LV → Status approved' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :success
      assert_equal 'approved', tr.reload.status
    end

    test 'approve_lv mit zukünftigem effective_date → Status scheduled' do
      tr = create_transfer_request(status: 'pending_lv', effective_date: Date.today + 10)
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'scheduled', body['status']
      assert_equal 'scheduled', tr.reload.status
    end

    test 'VM darf approve_lv nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :forbidden
    end

    # Der Fall aus api#512: Zwischen Antrag und LV-Genehmigung liegen zwei Mails
    # und die Spielerbestätigung, in der Praxis also Tage. Wird der Zielverein in
    # diesem Fenster deaktiviert, darf die Genehmigung nicht durchlaufen.
    test 'approve_lv in einen zwischenzeitlich deaktivierten Verein → 422' do
      tr = create_transfer_request(status: 'pending_lv')
      @requesting_club.update!(deactivated_at: Time.current)
      login(@sbk)
      assert_no_emails do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :unprocessable_entity
      assert_equal 'pending_lv', tr.reload.status
      assert_equal [@former_club.id], @player.reload.clubs.map { |c| c['club_id'] },
                   'die Zugehörigkeit darf sich durch den abgewiesenen Aufruf nicht ändern'
    end

    # Auch die Freigabe legt eine Mitgliedschaft im aufnehmenden Verein an, der
    # Riegel sitzt deshalb vor der Verzweigung nach request_type.
    test 'approve_lv einer Freigabe in einen deaktivierten Verein → 422' do
      tr = create_transfer_request(status: 'pending_lv', request_type: 'release')
      @requesting_club.update!(deactivated_at: Time.current)
      login(@sbk)
      assert_no_emails do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :unprocessable_entity
      assert_equal 'pending_lv', tr.reload.status
      assert_equal 1, @player.reload.clubs.size
    end

    # Gegenprobe zum Riegel vor der request_type-Verzweigung: Die Freigabe in
    # einen aktiven Verein läuft weiter durch.
    test 'approve_lv einer Freigabe in einen aktiven Verein → approved' do
      tr = create_transfer_request(status: 'pending_lv', request_type: 'release')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      assert_equal 'approved', tr.reload.status
      assert_includes @player.reload.clubs.map { |c| c['club_id'] }, @requesting_club.id
    end

    test 'approve_lv bei falschem Status → 422' do
      tr = create_transfer_request(status: 'pending_club')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :unprocessable_entity
    end

    # Der abgebende Verein arbeitet den Antrag ab, bevor die LV-Genehmigung
    # kommt. Ist der Zielverein bis dahin deaktiviert, ist der Antrag
    # aussichtslos, und die Bestätigungsmail an den Spieler waere umsonst.
    test 'approve_club in einen zwischenzeitlich deaktivierten Verein → 422' do
      tr = create_transfer_request(status: 'pending_club')
      @requesting_club.update!(deactivated_at: Time.current)
      login(@vm_former)
      assert_no_emails do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      end
      assert_response :unprocessable_entity
      assert_equal 'pending_club', tr.reload.status
    end

    # Die Suche gibt dieselbe Auskunft wie das Anlegen, statt einen Treffer zu
    # melden, der gleich danach auf 422 faellt.
    test 'search_player mit deaktiviertem aufnehmenden Verein → 422' do
      @requesting_club.update!(deactivated_at: Time.current)
      login(@vm_requesting)
      get '/api/v2/admin/transfer_requests/search_player', params: {
        first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
      assert_match(/deaktiviert/, JSON.parse(response.body)['error'])
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/execute
    # ---------------------------------------------------------------------------

    # Der geplante Transfer ist der deutlichste Fall aus api#512: Zwischen
    # Genehmigung und Vollzug liegen mindestens sieben Tage.
    test 'execute in einen zwischenzeitlich deaktivierten Verein → 422' do
      tr = create_transfer_request(status: 'scheduled')
      @requesting_club.update!(deactivated_at: Time.current)
      login(@sbk)
      assert_no_emails do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/execute"
      end
      assert_response :unprocessable_entity
      assert_equal 'scheduled', tr.reload.status
      assert_equal [@former_club.id], @player.reload.clubs.map { |c| c['club_id'] },
                   'die Zugehörigkeit darf sich durch den abgewiesenen Aufruf nicht ändern'
    end

    # Gegenprobe: Der reguläre Vollzug bleibt unberührt.
    test 'execute in einen aktiven Verein → Status approved' do
      tr = create_transfer_request(status: 'scheduled')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/execute"
      assert_response :success
      assert_equal 'approved', tr.reload.status
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/reject_lv
    # ---------------------------------------------------------------------------

    test 'SBK lehnt LV ab → Status rejected_by_lv' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
              params: { rejection_reason: 'Sperrfrist noch aktiv' }
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'rejected_by_lv', body['status']
      assert_equal 'rejected_by_lv', tr.reload.status
    end

    test 'Admin lehnt LV ab → Status rejected_by_lv' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
              params: { rejection_reason: 'Administrativer Grund' }
      end
      assert_response :success
      assert_equal 'rejected_by_lv', tr.reload.status
    end

    test 'reject_lv ohne Begründung → 422' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv"
      assert_response :unprocessable_entity
    end

    test 'VM darf reject_lv nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
            params: { rejection_reason: 'Kein Zugriff' }
      assert_response :forbidden
    end

    # ---------------------------------------------------------------------------
    # Userkennung: welches Konto hat gehandelt
    # ---------------------------------------------------------------------------

    # Die Konten standen längst in der Tabelle, wurden aber nie ausgeliefert.
    # Damit war nachträglich nicht zu klären, wer einen Transfer oder eine
    # Freigabe angelegt und genehmigt hat.
    test 'Antrag nennt das anlegende Konto mit Namen' do
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal @vm_requesting.id, body['created_by']
      assert_equal @vm_requesting.fullname, body['created_by_name']
    end

    test 'Vereinsfreigabe nennt das genehmigende Konto samt Zeitpunkt' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @vm_former.id, body['approved_by_club_user_id']
      assert_equal @vm_former.fullname, body['approved_by_club_user_name']
      assert body['club_approved_at'].present?, 'Zeitpunkt der Vereinsfreigabe muss mitreisen'
    end

    test 'LV-Genehmigung nennt das genehmigende Konto' do
      tr = create_transfer_request(status: 'pending_lv', effective_date: 1.month.from_now.to_date)
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @sbk.id, body['approved_by_lv_user_id']
      assert_equal @sbk.fullname, body['approved_by_lv_user_name']
    end

    test 'Ablehnung nennt das ablehnende Konto samt Zeitpunkt' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_club",
            params: { rejection_reason: 'Beitrag offen' }
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @vm_former.id, body['rejected_by']
      assert_equal @vm_former.fullname, body['rejected_by_name']
      assert body['rejected_at'].present?
    end

    # Der Abbruch war der einzige Vorgang ohne jede Spur: Anlegen, Freigabe,
    # Genehmigung, Ablehnung und Widerruf hielten ihr Konto fest, das
    # Zurückziehen und das Annullieren nicht.
    test 'Zurückziehen durch den Verein hält das Konto fest' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_requesting)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/withdraw"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'withdrawn', body['status']
      assert_equal @vm_requesting.id, body['withdrawn_by']
      assert_equal @vm_requesting.fullname, body['withdrawn_by_name']
      assert body['withdrawn_at'].present?
      assert_equal @vm_requesting.id, tr.reload.withdrawn_by
    end

    test 'Annullieren durch die SBK hält das Konto fest' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/cancel"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'withdrawn', body['status']
      assert_equal @sbk.id, body['withdrawn_by']
      assert_equal @sbk.fullname, body['withdrawn_by_name']
      assert_equal @sbk.id, tr.reload.withdrawn_by
    end

    test 'LV-Ablehnung nennt das ablehnende Konto' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
            params: { rejection_reason: 'Sperrfrist läuft' }
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @sbk.id, body['rejected_by']
      assert_equal @sbk.fullname, body['rejected_by_name']
      assert body['rejected_at'].present?
    end

    # Der Widerruf ist der einzige Schritt mit Begründungstext; die Chronik baut
    # ihn aus revoked_at, revoked_by und revocation_reason.
    test 'Widerruf einer Freigabe nennt das widerrufende Konto' do
      tr = create_transfer_request(status: 'pending_lv', request_type: 'release')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success

      patch "/api/v2/admin/transfer_requests/#{tr.id}/revoke",
            params: { revocation_reason: 'Irrtum bei der Freigabe' }
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal @sbk.id, body['revoked_by']
      assert_equal @sbk.fullname, body['revoked_by_name']
      assert body['revoked_at'].present?
      assert_equal 'Irrtum bei der Freigabe', body['revocation_reason']
    end

    # Die Person bestätigt über den Link in ihrer Mail, ohne Anmeldung. Der
    # Zeitpunkt muss mitreisen, ein Konto gibt es dazu nicht – die Chronik zeigt
    # den Schritt sonst gar nicht an.
    test 'Bestätigung durch die Person liefert den Zeitpunkt ohne Konto' do
      tr = create_transfer_request(status: 'pending_player')
      get '/api/v2/admin/transfer_requests/player_approve',
          params: { token: tr.player_confirmation_token }

      login(@admin)
      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success
      body = JSON.parse(response.body)
      assert body['player_approved_at'].present?, 'Zeitpunkt der Bestätigung muss mitreisen'
      assert_nil body['player_rejected_at']
    end

    # Bewusster Unterschied zum Spielerprofil: In der Transferansicht sind die
    # Vereine Partei des Vorgangs, sie sollen sehen, wer entschieden hat.
    test 'Vereinsmanager sieht die handelnden Konten seines Vorgangs' do
      tr = create_transfer_request(status: 'pending_lv', effective_date: 1.month.from_now.to_date)
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success

      login(@vm_requesting)
      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success
      assert_equal @sbk.fullname, JSON.parse(response.body)['approved_by_lv_user_name']
    end

    # Der Benutzername ist in diesem Projekt die halbe Anmeldung (Login läuft
    # allein über ihn) und hat in einer Ansicht, die auch den Vereinen offensteht,
    # nichts verloren. Für die Zuordnung genügen Name und Konto-ID.
    test 'Konto-Namen enthalten den Benutzernamen nicht' do
      tr = create_transfer_request(status: 'pending_club')
      login(@admin)
      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success

      name = JSON.parse(response.body)['created_by_name']
      assert_equal @vm_requesting.fullname, name
      assert_not_includes name.to_s, @vm_requesting.user_name
    end

    # Der dritte Weg in den Status "withdrawn" neben withdraw und cancel:
    # Club#deactivate! kennt das handelnde Konto (es steht in
    # clubs.deactivated_by), gab es aber nicht an den Antrag weiter. Ein so
    # beendeter Vorgang wäre in der Chronik der einzige ohne Abschlussschritt.
    test 'Vereinsdeaktivierung hält das handelnde Konto am Antrag fest' do
      tr = create_transfer_request(status: 'pending_club')

      @requesting_club.deactivate!(@admin.id)

      tr.reload
      assert_equal 'withdrawn', tr.status
      assert_equal @admin.id, tr.withdrawn_by
      assert tr.withdrawn_at.present?

      login(@admin)
      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success
      assert_equal @admin.fullname, JSON.parse(response.body)['withdrawn_by_name']
    end

    # Die Übersicht darf die Namen nicht je Zeile nachladen; der Aufwand wüchse
    # sonst mit der Zahl der Anträge. Gemessen wird der Zuwachs und nicht eine
    # absolute Zahl: Der Request fragt die users-Tabelle schon für die
    # Anmeldung und die Rechteprüfung mehrfach ab, das ist Bestand und hat mit
    # der Namensauflösung nichts zu tun.
    test 'Übersicht lädt die Konten nicht je Zeile nach' do
      # Je Spieler ist nur ein aktiver Antrag zulässig
      # (index_transfer_requests_on_player_id_active), die Liste braucht also
      # je Antrag eine eigene Person.
      first = create_request_for_new_player(@vm_requesting)
      login(@admin)

      with_one = count_user_queries { get '/api/v2/admin/transfer_requests' }
      assert_response :success
      assert_equal 1, JSON.parse(response.body).size

      # Drei verschiedene anlegende Konten: Bekämen alle Zeilen denselben Namen
      # aus der gemeinsamen Auflösung, bliebe das bei einem einzigen Konto
      # unbemerkt.
      second = create_request_for_new_player(@vm_former)
      third = create_request_for_new_player(@admin)

      with_three = count_user_queries { get '/api/v2/admin/transfer_requests' }
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 3, body.size
      by_id = body.index_by { |row| row['id'] }
      assert_equal @vm_requesting.fullname, by_id[first.id]['created_by_name']
      assert_equal @vm_former.fullname, by_id[second.id]['created_by_name']
      assert_equal @admin.fullname, by_id[third.id]['created_by_name']

      assert_equal with_one, with_three,
                   'zusätzliche Zeilen dürfen keine zusätzliche User-Abfrage kosten ' \
                   "(#{with_one} bei einer, #{with_three} bei drei Zeilen)"
    end

    # Ein zwischenzeitlich gelöschtes Konto darf die Antwort nicht sprengen; die
    # ID bleibt die belastbare Angabe.
    test 'unauffindbares Konto liefert die ID ohne Namen' do
      tr = create_transfer_request(status: 'pending_club')
      tr.update_columns(created_by: 999_999)
      login(@admin)
      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 999_999, body['created_by']
      assert_nil body['created_by_name']
    end
  end
end
