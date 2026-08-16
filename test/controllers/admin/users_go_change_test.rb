require 'test_helper'

module Admin
  # Verbund-Zuweisung über PATCH /api/v2/admin/users/:id (game_operation_id),
  # also das einzelne Dropdown der Benutzermaske.
  #
  # Regression zu #434. Die Begründung steht an `go_scope_conflict` in
  # `apply_go_change`; kurz: Der Schreibzweig setzt JEDE verbandsgebundene
  # Berechtigung auf die neue ID, und das ist nur verlustfrei, wenn alle auf
  # denselben echten Verband zeigen.
  class UsersGoChangeTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @a = create(:game_operation)
      @b = create(:game_operation)
      @c = create(:game_operation)
      @admin = create(:user, :admin)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    # Der zweite Wert je Paar ist entweder ein GameOperation, eine rohe ID
    # (für Integer/String-Mischformen aus dem Bestand) oder nil.
    def user_with(*permissions)
      create(:user, permissions: permissions.map do |(role, go, club)|
        perm = { 'user_group_id' => role }
        perm['game_operation_id'] = go.respond_to?(:id) ? go.id.to_s : go unless go == :absent
        perm['club_id'] = club.id.to_s if club
        perm
      end)
    end

    def go_ids_of(user, role)
      user.reload.permissions.select { |p| p['user_group_id'].to_i == role }
                             .map { |p| p['game_operation_id'].to_s }.sort
    end

    test 'zwei Verbaende in derselben Rolle werden nicht stillschweigend zu einem' do
      target = user_with([2, @a], [2, @b])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :unprocessable_entity
      assert_match(/mehreren Verbünden/, JSON.parse(response.body)['error'])
      assert_equal [@a.id.to_s, @b.id.to_s].sort, go_ids_of(target, 2)
      # Der eigentliche Schaden lag eine Ebene tiefer: permission_hash zieht das
      # überschriebene Array per uniq glatt, der Verlust ist dort unsichtbar.
      assert_equal [@a.id, @b.id].sort, target.reload.permission_hash[:sbk].sort
    end

    # Der realistischste Fall: Das Dropdown ist mit dem erstgefundenen Verband
    # vorbelegt, jemand speichert, ohne die Auswahl zu ändern. Vorher ging dabei
    # der zweite Verband verloren, ohne dass überhaupt etwas geändert werden
    # sollte.
    test 'auch das Speichern ohne Aenderung nimmt keinen Verband weg' do
      target = user_with([2, @a], [2, @b])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @a.id }

      assert_response :unprocessable_entity
      assert_equal [@a.id, @b.id].sort, target.reload.permission_hash[:sbk].sort
    end

    test 'zwei Verbaende in verschiedenen Rollen ebenso' do
      target = user_with([2, @a], [3, @b])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :unprocessable_entity
      assert_equal [@a.id.to_s], go_ids_of(target, 2)
      assert_equal [@b.id.to_s], go_ids_of(target, 3)
    end

    # Gegenprobe und der Grund, warum die Verbände gezählt werden und nicht die
    # Rollen: SBK und Ansetzer desselben Verbands sind der Normalfall.
    test 'mehrere Rollen im selben Verband ziehen gemeinsam um' do
      target = user_with([2, @a], [7, @a])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :success
      assert_equal [@c.id.to_s], go_ids_of(target, 2)
      assert_equal [@c.id.to_s], go_ids_of(target, 7)
    end

    test 'ein einzelner Verband wechselt weiterhin' do
      target = user_with([2, @a])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :success
      assert_equal [@c.id.to_s], go_ids_of(target, 2)
    end

    # --- Ein Scope, aber kein echter Verband ------------------------------------

    # Bundesweiter Zugriff hat nur EINEN Scope, fällt also nicht unter die
    # Mehrfach-Regel, verlöre durch den Wechsel aber alle Verbände außer dem
    # gewählten. Derselbe stille Rechteverlust wie #434, eine Datenform weiter.
    test 'bundesweiter Zugriff wird nicht auf einen Verband beschnitten' do
      target = create(:user, :sbk_global)
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :unprocessable_entity
      assert_match(/bundesweiten Zugriff/, JSON.parse(response.body)['error'])
      assert_equal [0], target.reload.permission_hash[:sbk]
    end

    # permission_hash liest einen Eintrag ohne Verbund über to_i als 0, also als
    # global. Der Wechsel beschnitte damit ebenfalls, und der Datenfehler wäre
    # beiläufig überschrieben statt gemeldet.
    test 'eine Rolle ohne Verbund wird als Datenfehler gemeldet' do
      target = user_with([2, :absent])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :unprocessable_entity
      assert_match(/keinen Verbund/, JSON.parse(response.body)['error'])
    end

    # --- Was die Zählung NICHT beeinflussen darf --------------------------------

    # Die Factory schreibt game_operation_id 0 in VM- und TM-Berechtigungen. Eine
    # Zählung über alle Rollen statt nur über GO_SCOPED_ROLES wiese damit jedes
    # gewöhnliche SBK-plus-VM-Konto ab.
    test 'eine VM-Rolle daneben zaehlt nicht als zweiter Verband' do
      club = create(:club)
      target = user_with([2, @a], [4, 0, club])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :success
      assert_equal [@c.id.to_s], go_ids_of(target, 2)
      assert_equal [club.id], target.reload.permission_hash[:vm]
    end

    # Im Bestand liegt dieselbe ID mal als Integer, mal als String. Ohne
    # Normalisierung zählte das als zwei Verbände, und ein Konto mit genau einem
    # wäre dauerhaft nicht mehr änderbar.
    test 'dieselbe ID als Integer und als String ist ein Verband' do
      target = user_with([2, @a.id], [7, @a.id.to_s])
      login(@admin)

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @c.id }

      assert_response :success
      assert_equal [@c.id.to_s], go_ids_of(target, 2)
      assert_equal [@c.id.to_s], go_ids_of(target, 7)
    end

    # --- Zuständigkeit geht vor -------------------------------------------------

    # Eine SBK aus Verband A sieht ein Konto mit Rollen in A und B (über A liegt
    # es in ihrem Bereich), darf es aber nicht bewegen. Sie bekommt eine
    # Rechte-Absage und erfährt nichts über die Verbandszuordnung eines Kontos,
    # das sie nur halb verwalten darf.
    #
    # Die Absage kommt hier schon aus `require_admin_for_elevated_target!`, also
    # vor `apply_go_change`. Genau deshalb ist die Reihenfolge im Controller
    # (Zuständigkeit vor Verbandsprüfung) die konsistente Fortsetzung und keine
    # Geschmacksfrage. Ein SBK ohne jede Überschneidung kommt gar nicht so weit,
    # `scoped_users` blendet das Konto vorher aus (404).
    test 'teilzustaendige SBK bekommt eine Rechte-Absage, nicht die Verbandsmeldung' do
      target = user_with([2, @a], [2, @b])
      login(create(:user, :sbk_scoped, game_operation_id: @a.id))

      patch "/api/v2/admin/users/#{target.id}", params: { game_operation_id: @a.id }

      assert_response :forbidden
      assert_no_match(/Verbünde|Verbund/, JSON.parse(response.body)['error'])
      assert_equal [@a.id, @b.id].sort, target.reload.permission_hash[:sbk].sort
    end

    # --- Der Ausweg, auf den die Meldungen verweisen ----------------------------

    test 'remove_role und add_role bewegen den zweiten Verband einzeln' do
      target = user_with([2, @a], [2, @b])
      login(@admin)

      delete "/api/v2/admin/users/#{target.id}/remove_role",
             params: { user_group_id: 2, game_operation_id: @b.id }, as: :json
      assert_response :success

      post "/api/v2/admin/users/#{target.id}/add_role",
           params: { user_group_id: 2, game_operation_id: @c.id }, as: :json
      assert_response :success

      assert_equal [@a.id.to_s, @c.id.to_s].sort, go_ids_of(target, 2)
      assert_equal [@a.id, @c.id].sort, target.reload.permission_hash[:sbk].sort
    end
  end
end
