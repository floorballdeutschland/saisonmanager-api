require 'test_helper'

# Die Stellen, die mit der Umstellung von einer Ruby-Schleife ueber alle Vereine
# auf `Club.home_clubs_of(go_ids)` gewechselt sind. Semantisch aequivalent, aber
# keine wurde vorher von einem Test mit einer REGIONALEN SBK-Rolle betreten: Die
# vorhandenen Tests loggen einen Admin (`game_operation_id: 0`) oder einen
# Vereinsmanager ein und nehmen damit jeweils den anderen Zweig.
#
# Zusaetzlich haengt hier der Fall des untergeordneten Verbands: Der Spielbetrieb
# des Verbunds muss die Vereine seiner Unterverbaende im Scope haben, ein
# Spielbetrieb AM Unterverband nicht.
class ResponsibilityScopeTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')

    @verbund = create(:state_association, name: 'SBK Ost')
    @kind = create(:state_association, name: 'Floorballverband Sachsen', parent: @verbund)
    @verbund_go = create(:game_operation, state_association_id: @verbund.id)
    # Ein Spielbetrieb AM Unterverband: zustaendig ist trotzdem der Verbund.
    @kind_go = create(:game_operation, state_association_id: @kind.id)

    @fremd_sa = create(:state_association)
    @fremd_go = create(:game_operation, state_association_id: @fremd_sa.id)

    @eigener = create(:club, name: 'Verein im Verbund', state_association_id: @verbund.id)
    @im_kind = create(:club, name: 'Verein im Unterverband', state_association_id: @kind.id)
    @fremder = create(:club, name: 'Fremder Verein', state_association_id: @fremd_sa.id)
    @ohne = create(:club, name: 'Ohne Landesverband', state_association_id: nil)
    @antragsteller = create(:user, :admin)
  end

  # PlayerChangeRequest.for_go (Korrekturantraege): Die Tests dazu loggen nur
  # Vereinsmanager und Admin ein, der umgestellte Zweig lief in keinem.
  test 'for_go nimmt die Vereine des Verbunds samt Unterverbaenden' do
    eigener = antrag_fuer(@eigener)
    im_kind = antrag_fuer(@im_kind)
    fremder = antrag_fuer(@fremder)

    ids = PlayerChangeRequest.for_go([@verbund_go.id]).pluck(:id)

    assert_includes ids, eigener.id
    assert_includes ids, im_kind.id, 'der Verbund ist auch fuer den Unterverband zustaendig'
    assert_not_includes ids, fremder.id
  end

  test 'for_go gibt einem Spielbetrieb am Unterverband nichts' do
    antrag_fuer(@im_kind)

    assert_empty PlayerChangeRequest.for_go([@kind_go.id]).pluck(:id)
  end

  test 'for_go nimmt bei globalem Scope alle Vereine' do
    ohne = antrag_fuer(@ohne)

    assert_includes PlayerChangeRequest.for_go([0]).pluck(:id), ohne.id
  end

  # TransferRequest.pending_for_lv: hatte bisher weder Aufrufer noch Test.
  test 'pending_for_lv nimmt die Vereine des Verbunds samt Unterverbaenden' do
    eigener = transfer_from(@eigener)
    im_kind = transfer_from(@im_kind)
    fremder = transfer_from(@fremder)

    ids = TransferRequest.pending_for_lv([@verbund_go.id]).pluck(:id)

    assert_includes ids, eigener.id
    assert_includes ids, im_kind.id
    assert_not_includes ids, fremder.id
  end

  test 'pending_for_lv gibt einem Spielbetrieb am Unterverband nichts' do
    transfer_from(@im_kind)

    assert_empty TransferRequest.pending_for_lv([@kind_go.id]).pluck(:id)
  end

  # Ein Verein ohne zustaendigen Spielbetrieb darf in keinem regionalen Scope
  # liegen. Das ist gewollt und der Grund, warum die Ablage-Vereine der
  # Bundesebene vorbehalten bleiben.
  test 'ein Verein ohne Landesverband liegt in keinem regionalen Scope' do
    antrag = antrag_fuer(@ohne)

    [@verbund_go, @kind_go, @fremd_go].each do |go|
      assert_not_includes PlayerChangeRequest.for_go([go.id]).pluck(:id), antrag.id,
                          "Spielbetrieb #{go.id} darf den Verein ohne Landesverband nicht sehen"
    end
  end

  private

  def antrag_fuer(club)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    PlayerChangeRequest.create!(player_id: player.id, club_id: club.id, status: 'pending',
                                correction_type: 'last_name', new_value: 'Neuer Name',
                                requested_by_user_id: @antragsteller.id)
  end

  def transfer_from(club)
    player = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    TransferRequest.create!(player_id: player.id, former_club_id: club.id,
                            requesting_club_id: @fremder.id, status: 'pending_lv',
                            season_id: Setting.current_season_id,
                            created_by: @antragsteller.id)
  end
end
