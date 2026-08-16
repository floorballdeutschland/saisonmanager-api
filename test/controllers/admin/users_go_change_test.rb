require 'test_helper'

module Admin
  # Verbund-Zuweisung über PATCH /admin/users/:id (game_operation_id), also das
  # einzelne Dropdown der Benutzermaske.
  #
  # apply_go_change schreibt JEDE verbandsgebundene Berechtigung
  # (GO_SCOPED_ROLES = SBK, RSK, Ansetzer) auf die neue ID um. Bei einem Konto
  # mit zwei Verbänden wurde aus [{SBK, A}, {SBK, B}] dabei [{SBK, A}, {SBK, A}],
  # User#permission_hash entdoppelte das per uniq, und der Zugriff auf Verband B
  # war weg. Antwort: 200, ohne jeden Hinweis (#434).
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

    def user_with(*permissions)
      create(:user, permissions: permissions.map do |(role, go)|
        { 'user_group_id' => role, 'game_operation_id' => go.id.to_s }
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

    # Der Weg, der auch mit zwei Verbänden korrekt umgeht, muss offen bleiben.
    test 'remove_role und add_role bewegen den zweiten Verband einzeln' do
      target = user_with([2, @a], [2, @b])
      login(@admin)

      delete "/api/v2/admin/users/#{target.id}/remove_role",
             params: { user_group_id: 2, game_operation_id: @b.id }
      assert_response :success

      post "/api/v2/admin/users/#{target.id}/add_role",
           params: { user_group_id: 2, game_operation_id: @c.id }
      assert_response :success

      assert_equal [@a.id.to_s, @c.id.to_s].sort, go_ids_of(target, 2)
    end
  end
end
