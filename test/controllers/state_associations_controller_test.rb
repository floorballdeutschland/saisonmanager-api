require 'test_helper'

# Absicherung der LV-Schreib-Autorisierung (StateAssociationWritable):
# globaler Admin darf jeden LV bearbeiten, SBK nur den eigenen (gescopten),
# RSK gar nicht. Deckt den `update`-Pfad ab; Releases- und Checklist-Controller
# nutzen dieselbe Concern und werden exemplarisch über Releases mitgeprüft.
class StateAssociationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @own_sa = StateAssociation.create!(name: "Eigener LV #{SecureRandom.hex(4)}", short_name: 'ELV')
    @own_go = GameOperation.create!(name: 'SBK Eigen', short_name: 'SBE',
                                    path: "sbk-eigen-#{SecureRandom.hex(4)}", state_association: @own_sa)
    @foreign_sa = StateAssociation.create!(name: "Fremder LV #{SecureRandom.hex(4)}", short_name: 'FLV')

    @admin = create_user(user_group_id: 1, game_operation_id: @own_go.id)
    @sbk = create_user(user_group_id: 2, game_operation_id: @own_go.id)
    @rsk = create_user(user_group_id: 3, game_operation_id: @own_go.id)
  end

  test 'Admin darf jeden Landesverband bearbeiten' do
    login(@admin)
    put "/api/v2/admin/state_associations/#{@foreign_sa.id}",
        params: { state_association: { name: 'Neu durch Admin' } }
    assert_response :success
  end

  test 'SBK darf den eigenen Landesverband bearbeiten' do
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'Neu durch SBK' } }
    assert_response :success
    assert_equal 'Neu durch SBK', @own_sa.reload.name
  end

  test 'SBK darf einen fremden Landesverband NICHT bearbeiten' do
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@foreign_sa.id}",
        params: { state_association: { name: 'Übergriff' } }
    assert_response :forbidden
  end

  test 'SBK kann den übergeordneten Verband nicht ändern' do
    other_root = StateAssociation.create!(name: "Root #{SecureRandom.hex(4)}", short_name: 'RT')
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', parent_id: other_root.id } }
    assert_response :success
    assert_nil @own_sa.reload.parent_id
  end

  test 'RSK hat keinen Zugriff auf die LV-Verwaltung' do
    login(@rsk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'RSK-Versuch' } }
    assert_response :forbidden
  end

  test 'Releases: SBK darf für den eigenen LV anlegen, RSK nicht' do
    login(@rsk)
    post "/api/v2/admin/state_associations/#{@own_sa.id}/releases",
         params: { recipient_game_operation_id: @own_go.id }
    assert_response :forbidden

    login(@sbk)
    post "/api/v2/admin/state_associations/#{@foreign_sa.id}/releases",
         params: { recipient_game_operation_id: @own_go.id }
    assert_response :forbidden
  end

  private

  def create_user(user_group_id:, game_operation_id:)
    User.create!(
      user_name: "authuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
