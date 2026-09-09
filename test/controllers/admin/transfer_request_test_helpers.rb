# Aufbauhelfer der Transferantrags-Tests: Konten, Vereine und Antraege.
#
# Ausgelagert, weil die Testklasse sonst ueber `Metrics/ClassLength` laeuft (die
# Grenze steht in .rubocop_todo.yml und wird nicht angehoben). Die Methoden
# lesen die Instanzvariablen des `setup` der einbindenden Klasse
# (@former_club, @requesting_club, @player, @vm_requesting).
module Admin
  module TransferRequestTestHelpers
    # Der gemeinsame Aufbau beider Transferantrags-Testklassen: ein
    # Landesverband mit Spielbetrieb, ein abgebender und ein aufnehmender
    # Verein darin, ein Spieler mit Heimatverein und je ein Konto pro Rolle.
    def setup_transfer_request_world
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

    def create_user(user_group_id:, game_operation_id: 0, club_id: nil)
      permissions = if club_id
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id, 'club_id' => club_id }]
                    else
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }]
                    end
      # Mit Vor- und Nachnamen: Ohne sie liefert User#fullname nur ein
      # Leerzeichen, und die Tests zur Userkennung würden gegen einen leeren
      # String prüfen, statt gegen den Namen, um den es geht.
      User.create!(
        first_name: "Vor#{SecureRandom.hex(3)}",
        last_name: "Nach#{SecureRandom.hex(3)}",
        user_name: "user_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: permissions,
        teams: []
      )
    end

    # Der abgebende Verein ohne jeden Bearbeiter: kein Postfach und kein Konto
    # mit der VM-Rolle für diesen Verein (api#581). Das setup gibt ihm beides.
    def make_former_club_unreachable
      @former_club.update!(contact_email: nil)
      @vm_former.update!(permissions: [])
    end

    def create_club_in_other_game_operation
      state_association = StateAssociation.create!(
        name: "Anderer LV #{SecureRandom.hex(4)}",
        short_name: "ALV#{SecureRandom.hex(2)}"
      )
      GameOperation.create!(
        name: "Anderer Spielbetrieb #{SecureRandom.hex(4)}",
        short_name: "ASB#{SecureRandom.hex(2)}",
        state_association: state_association
      )
      Club.create!(
        name: "Anderer Verein #{SecureRandom.hex(4)}",
        short_name: "AN#{SecureRandom.hex(1)}",
        contact_email: 'other@test.example.com',
        state_association: state_association
      )
    end

    def create_user_sbk(game_operation_id:)
      User.create!(
        first_name: "Vor#{SecureRandom.hex(3)}",
        last_name: "Nach#{SecureRandom.hex(3)}",
        user_name: "sbk_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 2, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def create_user_sbk_and_vm(game_operation_id:, club_id:)
      User.create!(
        first_name: "Vor#{SecureRandom.hex(3)}",
        last_name: "Nach#{SecureRandom.hex(3)}",
        user_name: "sbkvm_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [
          { 'user_group_id' => 2, 'game_operation_id' => game_operation_id },
          { 'user_group_id' => 4, 'club_id' => club_id.to_s }
        ],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def create_request_for_new_player(creator = @vm_requesting)
      TransferRequest.create!(
        player: create(:player), requesting_club: @requesting_club, former_club: @former_club,
        status: 'pending_club', created_by: creator.id, season_id: 18
      )
    end

    def count_user_queries(&block)
      queries = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        queries += 1 if payload[:sql]&.include?('"users"')
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
      queries
    end

    # Ein eingehender Vorgang: Der aufnehmende Verein liegt im Spielbetrieb des
    # Tests, der abgebende ausserhalb. Je Aufruf ein eigener Spieler, damit die
    # partiellen Unique-Indizes auf player_id nicht dazwischenkommen.
    def create_incoming_request(status: 'approved', request_type: 'transfer',
                                former_club: nil, requesting_club: nil)
      TransferRequest.create!(
        player: create(:player),
        requesting_club: requesting_club || @requesting_club,
        former_club: former_club || create_club_in_other_game_operation,
        status: status,
        created_by: @vm_requesting.id,
        season_id: 18,
        request_type: request_type,
        lv_approved_at: (Time.current if status.in?(%w[approved scheduled])),
        rejection_reason: ('Testgrund' if status.start_with?('rejected'))
      )
    end

    def create_transfer_request(status:, effective_date: nil, request_type: 'transfer')
      # token wird im before_create callback generiert; bei direkt gesetztem
      # Status (z.B. pending_lv) ist er trotzdem vorhanden.
      TransferRequest.create!(
        player: @player,
        requesting_club: @requesting_club,
        former_club: @former_club,
        status: status,
        created_by: @vm_requesting.id,
        season_id: 18,
        effective_date: effective_date,
        request_type: request_type
      )
    end
  end
end
