require 'test_helper'

module Admin
  # Fokus: der neue Merge-Antragstyp (VM schlägt Zusammenführung vor,
  # Admin/SBK genehmigt und führt damit den Merge aus).
  class PlayerChangeRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')

      @club = Club.create!(name: "Verein #{SecureRandom.hex(4)}")
      @other_club = Club.create!(name: "Anderer Verein #{SecureRandom.hex(4)}")

      @master = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
      @duplicate = create(:player, first_name: @master.first_name, last_name: @master.last_name,
                                   clubs: [{ 'club_id' => @club.id, 'home_club' => true }])

      @vm = create_user(user_group_id: 4, club_id: @club.id)
      @vm_other = create_user(user_group_id: 4, club_id: @other_club.id)
      @admin = create_user(user_group_id: 1, game_operation_id: 0)
    end

    test 'VM legt Merge-Antrag für Spieler des eigenen Vereins an' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @duplicate.id
      }

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'pending', body['status']
      assert_equal @duplicate.id, body.dig('secondary_player', 'id')
    end

    test 'VM eines anderen Vereins darf keinen Antrag für fremden Verein anlegen' do
      login(@vm_other)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @duplicate.id
      }

      assert_response :forbidden
    end

    test 'Merge-Antrag für Spieler, der nicht zum Verein gehört, wird abgelehnt' do
      clubless = create(:player)
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: clubless.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @duplicate.id
      }

      assert_response :forbidden
    end

    test 'Merge-Antrag mit vereinsfremdem Duplikat wird abgelehnt' do
      foreign = create(:player, clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }])
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: foreign.id
      }

      assert_response :unprocessable_entity
    end

    test 'Merge-Antrag ohne secondary_player_id wird abgelehnt' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id, correction_type: 'merge'
      }

      assert_response :unprocessable_entity
    end

    test 'Admin-Approve führt die Spieler zusammen' do
      request = create_merge_request
      login(@admin)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :success
      assert_equal 'approved', request.reload.status
      assert_equal @master.id, @duplicate.reload.merged_into_id
      assert_predicate @duplicate.deactivated_at, :present?
    end

    test 'VM darf nicht genehmigen' do
      request = create_merge_request
      login(@vm)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :forbidden
      assert_equal 'pending', request.reload.status
    end

    test 'Approve liefert 422, wenn das Duplikat inzwischen anderweitig gemergt wurde' do
      request = create_merge_request
      @duplicate.update_columns(merged_into_id: @master.id)

      login(@admin)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :unprocessable_entity
      assert_equal 'pending', request.reload.status
    end

    # ------------------------------------------------------------------------
    # Vereinsprüfung: Gültigkeit der Zugehörigkeit, und für jede Antragsart
    # ------------------------------------------------------------------------

    # Der Kern des Befunds: Vorher genügte jeder je bestandene Eintrag im
    # clubs-Hash. Der VM eines Vereins, den der Spieler verlassen hat, konnte
    # damit einen Antrag gegen ihn stellen.
    test 'VM eines verlassenen Vereins darf keinen Antrag stellen' do
      gone = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'valid_until' => 2.years.ago.to_s }])
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: gone.id, club_id: @club.id, correction_type: 'last_name', new_value: 'Neu'
      }

      assert_response :forbidden
      assert_equal 0, PlayerChangeRequest.where(player_id: gone.id).count
    end

    test 'eine heute endende Zugehörigkeit deckt den Antrag noch' do
      today = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                        'valid_until' => Date.current.to_s }])
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: today.id, club_id: @club.id, correction_type: 'last_name', new_value: 'Neu'
      }

      assert_response :created
    end

    # Ein deaktivierter Spieler des eigenen Vereins steht in der VM-Spielerliste
    # (Club#players mit include_deactivated) und muss korrigierbar bleiben,
    # obwohl deactivate! alle Zugehörigkeiten geschlossen hat.
    test 'ein selbst deaktivierter Spieler bleibt korrigierbar' do
      player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
      player.deactivate!(@vm.id, reason: 'Vereinsaustritt')
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: player.id, club_id: @club.id, correction_type: 'names_swapped'
      }

      assert_response :created
    end

    # Der zweite Teil des Befunds: Der Guard griff nur bei 'merge'. Gegen die
    # übrigen sechs Antragsarten ließ sich ein Antrag zu jeder beliebigen
    # Spieler-ID stellen.
    test 'keine Antragsart lässt einen vereinsfremden Spieler durch' do
      foreign = create(:player, clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }])
      login(@vm)

      params_per_type = {
        'birthdate' => { new_value: '2000-01-01' },
        'first_name' => { new_value: 'Neu' },
        'last_name' => { new_value: 'Neu' },
        'names_swapped' => {},
        'nationality' => { new_value: '1' },
        'gender' => { new_value: 'W' },
        'merge' => { secondary_player_id: @duplicate.id }
      }

      params_per_type.each do |type, extra|
        post '/api/v2/admin/player_change_requests.json',
             params: { player_id: foreign.id, club_id: @club.id, correction_type: type }.merge(extra)

        assert_response :forbidden, "Antragsart #{type} muss abgewiesen werden"
      end

      assert_equal 0, PlayerChangeRequest.where(player_id: foreign.id).count
    end

    # Gegenrichtung: Alle Antragsarten müssen für einen Spieler des eigenen
    # Vereins weiterhin durchgehen.
    test 'alle Antragsarten gehen für einen Spieler des eigenen Vereins durch' do
      login(@vm)

      { 'birthdate' => { new_value: '2000-01-01' },
        'first_name' => { new_value: 'Neu' },
        'last_name' => { new_value: 'Neu' },
        'names_swapped' => {},
        'nationality' => { new_value: '1' },
        'gender' => { new_value: 'W' } }.each do |type, extra|
        post '/api/v2/admin/player_change_requests.json',
             params: { player_id: @master.id, club_id: @club.id, correction_type: type }.merge(extra)

        assert_response :created, "Antragsart #{type} muss erlaubt bleiben"
      end
    end

    # Duplikat mit abgelaufener Zugehörigkeit: 422 wie beim vereinsfremden
    # Duplikat, nicht 403 – ein 403 würde den VM aus der Bearbeitung auf die
    # Startseite werfen (ErrorInterceptor).
    test 'Duplikat mit abgelaufener Zugehörigkeit wird abgelehnt' do
      gone = create(:player, first_name: @master.first_name, last_name: @master.last_name,
                             clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'valid_until' => 2.years.ago.to_s }])
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: gone.id
      }

      assert_response :unprocessable_entity
      assert_equal 0, PlayerChangeRequest.where(secondary_player_id: gone.id).count
    end

    # params[:club_id].to_i brach bei einem Array mit NoMethodError ab, also
    # einem 500er allein durch die Nutzlast. Kein Sicherheitsproblem (gespeichert
    # wurde nichts), aber die Zuständigkeitsprüfung hängt an diesem Wert.
    test 'ein Verein als Array bricht den Antrag nicht mit einem Serverfehler ab' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: [@club.id], correction_type: 'names_swapped'
      }

      assert_response :unprocessable_entity
      assert_equal 0, PlayerChangeRequest.count
    end

    # Gegenrichtung: Die Oberfläche schickt JSON, der Verein kommt dort als Zahl.
    test 'ein Verein als JSON-Zahl geht durch' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json',
           params: { player_id: @master.id, club_id: @club.id, correction_type: 'names_swapped' }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      assert_response :created
    end

    private

    def create_merge_request
      PlayerChangeRequest.create!(
        player: @master, club: @club, correction_type: 'merge',
        secondary_player: @duplicate, status: 'pending', requested_by_user_id: @vm.id
      )
    end

    def create_user(user_group_id:, game_operation_id: 0, club_id: nil)
      permissions = if club_id
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id, 'club_id' => club_id }]
                    else
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }]
                    end
      User.create!(
        user_name: "user_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: permissions,
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
