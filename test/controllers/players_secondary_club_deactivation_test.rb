require 'test_helper'

# Seit api#472 ist die Deaktivierung eine Kennzeichnung der Vereinsansicht, und wer
# neu aufgenommen wird, verliert sie (Player#clear_deactivation) — sonst fiele die
# Person im aufnehmenden Verein sofort wieder aus der aktiven Liste.
#
# Der Befund (api#476): Von den beiden Wegen zu einem Zweitspielrecht rief nur einer
# die Methode. Ueber die Vereinsfreigabe im Transferantrag wurde die Kennzeichnung
# abgeraeumt, ueber die Direktzuweisung der SBK nicht — dasselbe Zweitspielrecht,
# zwei verschiedene Ergebnisse. Im zweiten Fall stand der Eintrag in `player.clubs`,
# aber `Club#players` filtert ohne `include_deactivated` auf `Player.active`: Der
# aufnehmende Verein sah die Person nicht in seiner Spielerliste und konnte fuer sie
# keine Lizenz beantragen, obwohl das Zweitspielrecht angelegt war.
class PlayersSecondaryClubDeactivationTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @home_club = club_in(@go)
    @second_club = club_in(@go)
    @sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
    @player = create(:player, clubs: [{ 'club_id' => @home_club.id, 'home_club' => true }])
  end

  test 'Direktzuweisung raeumt die Kennzeichnung ab' do
    @player.deactivate!(@sbk.id, reason: 'Pause')
    login_as(@sbk)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_nil @player.reload.deactivated_at
    assert_nil @player.deactivated_by
  end

  # Der eigentliche Schaden, deshalb ueber die Vereinsspielerliste geprueft und nicht
  # nur ueber die Spalte: Ohne das Abraeumen legt die SBK ein Zweitspielrecht an, das
  # der aufnehmende Verein nirgends sieht.
  test 'der aufnehmende Verein sieht die Person danach in seiner Spielerliste' do
    @player.deactivate!(@sbk.id, reason: 'Pause')
    login_as(@sbk)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_includes @second_club.players.map(&:id), @player.id
  end

  # Die andere Haelfte derselben Entscheidung, hier festgehalten damit sie nicht
  # versehentlich zurueckgedreht wird: Die Kennzeichnung ist global, also sieht auch
  # der abgebende Verein die Person wieder in seiner Liste. Gewollt laut Ruecksprache
  # an api#476 — wer eine Aufnahme mittraegt, sieht die Person nicht mehr als inaktiv
  # an, und er kann sie bei sich jederzeit erneut deaktivieren.
  test 'der abgebende Verein sieht die Person ebenfalls wieder' do
    @player.deactivate!(@sbk.id, reason: 'Pause')
    login_as(@sbk)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_includes @home_club.players.map(&:id), @player.id
  end

  # Gegenprobe zum Weg ueber den Antrag: Beide Wege legen denselben Eintrag an und
  # muessen zum selben Ergebnis kommen.
  test 'Vereinsfreigabe im Antrag kommt zum selben Ergebnis' do
    @player.deactivate!(@sbk.id, reason: 'Pause')
    request = TransferRequest.new(player_id: @player.id, requesting_club_id: @second_club.id)

    request.send(:add_secondary_club_membership!, @sbk.id)

    assert_nil @player.reload.deactivated_at
    assert_includes @second_club.players.map(&:id), @player.id
  end

  # Der Grund ist Historie, die Kennzeichnung ist der Zustand — wie bei reactivate!.
  test 'der Deaktivierungsgrund bleibt stehen' do
    @player.deactivate!(@sbk.id, reason: 'Pause')
    login_as(@sbk)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_equal 'Pause', @player.reload.deactivation_reason
  end

  test 'ein aktives Profil bleibt unberuehrt und bekommt sein Zweitspielrecht' do
    login_as(@sbk)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_nil @player.reload.deactivated_at
    assert_includes @second_club.players.map(&:id), @player.id
  end

  # Der Grund fuer `save!(validate: false)`: Player verlangt eine nation_id, der
  # Altdaten-Import setzt sie nie. Mit Validierung bekam genau die betroffene
  # Population 422 statt eines Zweitspielrechts, waehrend dieselbe Aufnahme ueber den
  # Transferantrag durchlief.
  test 'ein Legacy-Profil ohne Nationalitaet bekommt sein Zweitspielrecht' do
    legacy = create(:player, clubs: [{ 'club_id' => @home_club.id, 'home_club' => true }])
    legacy.update_columns(nation_id: nil)
    assert_not legacy.reload.valid?, 'Vorbedingung: das Profil besteht die Validierung nicht'
    legacy.deactivate!(@sbk.id, reason: 'Vereinsaustritt')
    login_as(@sbk)

    post "/api/v2/admin/players/#{legacy.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :success
    assert_nil legacy.reload.deactivated_at
    assert_includes @second_club.players.map(&:id), legacy.id
  end

  # Bereits vorhandenes Zweitspielrecht: Der Aufruf lehnt ab und laesst die
  # Kennzeichnung stehen. Festgehalten, weil die Meldung nach Ordnung klingt, der
  # aufnehmende Verein die Person aber weiterhin nicht sieht — in dem Fall ist
  # `reactivate` der richtige Griff, nicht ein zweiter Versuch.
  test 'ein bereits vorhandenes Zweitspielrecht raeumt die Kennzeichnung nicht ab' do
    login_as(@sbk)
    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }
    assert_response :success

    @player.reload.deactivate!(@sbk.id, reason: 'Pause')
    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: @second_club.id }

    assert_response :unprocessable_entity
    assert_not_nil @player.reload.deactivated_at
  end

  private

  def club_in(game_operation)
    create(:club, state_association_id: @sa.id,
                  game_operations_hash: [{ 'home_game_operation' => true,
                                           'game_operation_id' => game_operation.id }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end
end
