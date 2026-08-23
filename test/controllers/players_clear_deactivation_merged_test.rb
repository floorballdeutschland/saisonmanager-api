require 'test_helper'

# api#486: `PlayersController#reactivate` lehnt eine zusammengefuehrte Dublette
# ausdruecklich ab, weil sie reaktiviert wieder ein zweites Profil derselben
# Person waere. `Player#clear_deactivation` pruefte `merged_into_id` an keinem
# der drei Aufnahmewege: Wurde eine Dublette darueber aufgenommen, war die
# Kennzeichnung weg und sie stand wieder in der Vereinsspielerliste und in der
# Auswahl beim Lizenzantrag, neben dem fuehrenden Profil.
#
# Ein Test je Aufrufweg, plus die Gegenprobe: Ein regulaer deaktiviertes Profil
# wird weiter aufgenommen (api#472).
class PlayersClearDeactivationMergedTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @former_club = create(:club, game_operation: @go)
    @new_club = create(:club, game_operation: @go)
    @admin = create(:user, :admin)
  end

  test 'clear_deactivation raeumt die Kennzeichnung einer Dublette nicht ab' do
    dublette = merged_player

    assert_equal false, dublette.clear_deactivation
    assert_not_nil dublette.deactivated_at
  end

  # Weg 1: Player#transfer, aufgerufen aus TransferRequest#execute_transfer!.
  test 'Player#transfer laesst die Dublette gekennzeichnet' do
    dublette = merged_player

    dublette.transfer(@new_club.id, @admin.id)

    assert_not_nil dublette.reload.deactivated_at,
                   'der Transfer darf die Merge-Kennzeichnung nicht abraeumen'
  end

  # Weg 2: PlayersController#transfer, der direkte Vereinswechsel. Die Aktion
  # braucht eine OFFENE Heimat-Zugehoerigkeit, sonst bricht sie schon vorher mit
  # „Konnte alten Verein nicht finden" ab und erreicht clear_deactivation nie --
  # ein Test auf die frisch zusammengefuehrte Dublette waere tautologisch. Der
  # offene Eintrag steht hier fuer den Bestand: eine Dublette, die nach dem Merge
  # wieder eine laufende Zugehoerigkeit hat.
  test 'players#transfer laesst die Dublette gekennzeichnet' do
    dublette = merged_player
    dublette.update_columns(clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }])
    login_as(@admin)

    post "/api/v2/admin/players/#{dublette.id}/transfer", params: { club_id: @new_club.id }

    assert_response :success, 'Vorbedingung: der Aufruf muss bis clear_deactivation kommen'
    assert_not_nil dublette.reload.deactivated_at
  end

  # Weg 3: TransferRequest#add_secondary_club_membership!, die Vereins-Freigabe.
  test 'die Freigabe laesst die Dublette gekennzeichnet' do
    dublette = merged_player
    tr = TransferRequest.create!(
      player: dublette, requesting_club: @new_club, former_club: @former_club,
      status: 'pending_lv', request_type: 'release', created_by: @admin.id,
      season_id: Setting.current_season_id
    )

    tr.send(:add_secondary_club_membership!, @admin.id)

    assert_not_nil dublette.reload.deactivated_at
    assert_includes dublette.clubs.map { |c| c['club_id'] }, @new_club.id,
                    'die Mitgliedschaft selbst entsteht weiter, nur die Kennzeichnung bleibt'
  end

  # Gegenprobe: Wer aus der Liste seines Vereins genommen wurde, ist im
  # aufnehmenden Verein wieder aktiv (api#472). Diese Wirkung bleibt.
  test 'ein regulaer deaktiviertes Profil wird beim Transfer wieder aktiv' do
    player = player_in_former_club
    player.deactivate!(@admin.id, reason: 'Vereinsaustritt')

    player.transfer(@new_club.id, @admin.id)

    assert_nil player.reload.deactivated_at
  end

  private

  def player_in_former_club
    create(:player, clubs: [{ 'club_id' => @former_club.id, 'home_club' => true }])
  end

  # merge_into! deaktiviert die Dublette und setzt merged_into_id.
  def merged_player
    dublette = player_in_former_club
    master = create(:player, clubs: [{ 'club_id' => @former_club.id, 'home_club' => true }])
    dublette.merge_into!(master, @admin.id)
    assert_not_nil dublette.reload.deactivated_at, 'Vorbedingung: der Merge kennzeichnet die Dublette'
    dublette
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end
end
