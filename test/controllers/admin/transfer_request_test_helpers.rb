# Aufbauhelfer der Transferantrags-Tests: Konten, Vereine und Antraege.
#
# Ausgelagert, weil die Testklasse sonst ueber `Metrics/ClassLength` laeuft (die
# Grenze steht in .rubocop_todo.yml und wird nicht angehoben). Die Methoden
# lesen die Instanzvariablen des `setup` der einbindenden Klasse
# (@former_club, @requesting_club, @player, @vm_requesting).
module Admin
  module TransferRequestTestHelpers
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
