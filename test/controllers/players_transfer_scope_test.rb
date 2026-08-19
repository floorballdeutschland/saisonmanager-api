require 'test_helper'

# Spielbetriebs-Scope der beiden Aktionen, die eine Vereinszugehörigkeit
# SCHREIBEN: transfer (Heimatverein wechseln) und add_additional_club
# (Zweitspielrecht). Eigene Datei, weil players_controller_test bereits an der
# Zeilengrenze liegt.
#
# Der Befund (#398): Beide prüften nur, OB jemand eine Spielbetriebsrolle hat,
# nicht WELCHEN Spielbetrieb. Der Transfer schreibt dabei einen Eintrag mit
# `home_club: true` – wer ihn ausführt, ist danach regulär zuständig und
# passiert jede weitere Prüfung. Die Verschärfungen aus #391 und #394
# begrenzten damit nur den bequemen Weg, nicht den Zugriff.
class PlayersTransferScopeTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation, state_association_id: create(:state_association).id)
  end

  test 'transfer: fremde SBK kann kein fremdes Profil in den eigenen Verband ziehen' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))

    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: foreign[:club].id }

    assert_response :forbidden
    assert_not_includes home_club_ids(player), foreign[:club].id,
                        'der Heimatverein darf sich durch den abgewiesenen Aufruf nicht ändern'
  end

  test 'add_additional_club: fremde SBK kommt ebenso wenig durch' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))

    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }

    assert_response :forbidden
    assert_equal 1, player.reload.clubs.size
  end

  # Die eigene Zuständigkeit endet am Zielverein: Auch der für den Spieler
  # zuständige SBK darf ihn nicht in einen Verein eines fremden Spielbetriebs
  # setzen.
  test 'transfer: zustaendige SBK darf nicht in einen fremden Spielbetrieb setzen' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: foreign[:club].id }

    assert_response :forbidden
    assert_not_includes home_club_ids(player), foreign[:club].id
  end

  # Bewusste Entscheidung, hier festgehalten, damit sie nicht versehentlich
  # zurückgedreht wird: Eine Vereins-Freigabe macht einen fremden Verein LESBAR,
  # sie holt ihn aber nicht in den eigenen Spielbetrieb. Ein Wechsel dorthin
  # bleibt ein Wechsel über Spielbetriebe hinweg und gehört in den Transferantrag
  # oder zur bundesweiten SBK. Wäre die Prüfung über
  # `readable_by_game_operations?` gebaut, ginge dieser Fall durch.
  test 'transfer: eine Vereins-Freigabe erlaubt keinen Transfer in den fremden Verein' do
    player = player_homed_in(@go)
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    released = create(:club, state_association_id: grantor_sa.id, game_operation: grantor_go)
    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: @go.id,
                                    season_id: Setting.current_season_id)
    assert released.readable_by_game_operations?([@go.id]),
           'Vorbedingung: der Verein ist über die Freigabe lesbar'

    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: released.id }

    assert_response :forbidden
    assert_not_includes home_club_ids(player), released.id
  end

  # Gegenrichtung, und die fachliche Regel: Die zuständige SBK darf innerhalb
  # ihres Spielbetriebs weiter direkt transferieren.
  test 'transfer: zustaendige SBK darf innerhalb des eigenen Spielbetriebs' do
    player = player_homed_in(@go)
    target = club_in(@go)
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: target.id }

    assert_response :success
    assert_equal [target.id], home_club_ids(player)
  end

  # Der Wechsel über Spielbetriebe hinweg bleibt der bundesweiten Rolle
  # vorbehalten; sonst führt der Weg über den Transferantrag mit LV-Freigabe.
  test 'transfer: bundesweite SBK darf ueber Spielbetriebe hinweg' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_global))

    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: foreign[:club].id }

    assert_response :success
    assert_equal [foreign[:club].id], home_club_ids(player)
  end

  private

  def club_in(game_operation)
    create(:club, game_operation: game_operation)
  end

  # Eigener Spieler statt einer geteilten Vorrichtung: Die Fabrik :club setzt
  # KEINEN Heimat-Spielbetrieb, main_game_operation_id bliebe nil und damit
  # ausserhalb jedes SBK-Scopes. Ein Test darauf prüfte den Datenmangel, nicht
  # die Regel.
  def player_homed_in(game_operation)
    create(:player, clubs: [{ 'club_id' => club_in(game_operation).id, 'home_club' => true }])
  end

  def foreign_go_with_club
    go = create(:game_operation, state_association_id: create(:state_association).id)
    { go: go, club: club_in(go) }
  end

  # club_ids der aktuell gültigen Heimat-Zugehörigkeiten.
  def home_club_ids(player)
    current = (player.reload.clubs || []).select do |c|
      ActiveModel::Type::Boolean.new.cast(c['home_club']) &&
        (c['valid_until'].nil? || c['valid_until'].to_time > Time.current)
    end
    current.map { |c| c['club_id'] }
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end
end
