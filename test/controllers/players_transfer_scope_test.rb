require 'test_helper'

# Spielbetriebs-Scope der Aktionen, die eine Vereinszugehörigkeit SCHREIBEN:
# transfer (Heimatverein wechseln) sowie add_additional_club und
# remove_additional_club (Freigabe/Zweitspielrecht erteilen und beenden). Eigene
# Datei, weil players_controller_test bereits an der Zeilengrenze liegt.
#
# Der Befund (#398): Alle prüften nur, OB jemand eine Spielbetriebsrolle hat,
# nicht WELCHEN Spielbetrieb. Der Transfer schreibt dabei einen Eintrag mit
# `home_club: true` – wer ihn ausführt, ist danach regulär zuständig und
# passiert jede weitere Prüfung. Die Verschärfungen aus #391 und #394
# begrenzten damit nur den bequemen Weg, nicht den Zugriff.
#
# Seit api#417 galt für beide Schreibwege dieselbe Regel, und das war für die
# Freigabe zu eng (Meldung vom 27.08.2026): Sie schreibt `home_club: false`, der
# abgebende Verband behält das Mitglied, und es entsteht keine Zuständigkeit, vor
# der zu schützen wäre. Maßgeblich ist für sie deshalb allein der abgebende
# Verband – dieselbe Regel wie im Antragsweg. Für den Transfer gilt die engere
# Regel unverändert weiter.
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

  # Für die Freigabe bleibt die Zuständigkeit für den SPIELER die Bedingung: Eine
  # fremde SBK kommt an ein Profil, das sie nichts angeht, weiterhin nicht heran.
  test 'add_additional_club: fremde SBK kommt ebenso wenig durch' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))

    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }

    assert_response :forbidden
    assert_equal 1, player.reload.clubs.size
  end

  # Die fachliche Regel der Freigabe, und der gemeldete Fall: Wer den Spieler
  # hat, darf ihn überall hin freigeben. Der Zielverein liegt in einem fremden
  # Spielbetrieb, der Heimatverein im eigenen -- seit api#417 lief genau das in
  # ein 403, obwohl der Antragsweg dieselbe Freigabe zulässt
  # (Admin::TransferRequestsController#sbk_may_assign?).
  test 'add_additional_club: zustaendige SBK darf in einen fremden Spielbetrieb freigeben' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }

    assert_response :success
    eintrag = player.reload.clubs.find { |c| c['club_id'] == foreign[:club].id }
    assert eintrag, 'die Freigabe muss geschrieben sein'
    assert_equal false, eintrag['home_club'],
                 'eine Freigabe ist kein Vereinswechsel und verschafft keine Zustaendigkeit'
    assert_equal 1, home_club_ids(player).size, 'der Heimatverein bleibt unberuehrt'
  end

  # Gegenprobe zur Abgrenzung: Derselbe Zielverein, derselbe Handelnde -- der
  # Transfer bleibt verboten. Die Lockerung gilt allein der Freigabe.
  test 'add_additional_club gelockert, transfer nicht' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }
    assert_response :success

    post "/api/v2/admin/players/#{player.id}/transfer", params: { club_id: foreign[:club].id }
    assert_response :forbidden
  end

  # Beenden ist die Kehrseite des Erteilens und braucht dieselbe Zuständigkeit.
  # Geprüft wurde bisher nur, OB eine Spielbetriebsrolle vorliegt: Jede
  # Landes-SBK konnte jede Freigabe jedes Profils im Bundesgebiet beenden.
  test 'remove_additional_club: fremde SBK darf eine Freigabe nicht beenden' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }
    assert_response :success
    valid_until = player.reload.clubs.find { |c| c['club_id'] == foreign[:club].id }['valid_until']

    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))
    post "/api/v2/admin/players/#{player.id}/remove_additional_club",
         params: { club_id: foreign[:club].id, valid_until: valid_until }

    assert_response :forbidden
    assert_equal valid_until, player.reload.clubs.find { |c| c['club_id'] == foreign[:club].id }['valid_until'],
                 'der abgewiesene Aufruf darf die Freigabe nicht beenden'
  end

  test 'remove_additional_club: die zustaendige SBK darf beenden' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }
    assert_response :success
    valid_until = player.reload.clubs.find { |c| c['club_id'] == foreign[:club].id }['valid_until']

    post "/api/v2/admin/players/#{player.id}/remove_additional_club",
         params: { club_id: foreign[:club].id, valid_until: valid_until }

    assert_response :success
    beendet = player.reload.clubs.find { |c| c['club_id'] == foreign[:club].id }['valid_until']
    assert beendet.to_time <= Time.current, 'die Freigabe muss beendet sein'
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
  # zurückgedreht wird -- sie gilt für den TRANSFER: Eine Vereins-Freigabe macht
  # einen fremden Verein LESBAR, sie holt ihn aber nicht in den eigenen
  # Spielbetrieb. Ein Wechsel dorthin bleibt ein Wechsel über Spielbetriebe
  # hinweg und gehört in den Transferantrag oder zur bundesweiten SBK. Wäre die
  # Prüfung über `readable_by_game_operations?` gebaut, ginge dieser Fall durch.
  # Die Spieler-Freigabe fragt nach dem Zielverein gar nicht mehr, für sie ist
  # der Fall gegenstandslos.
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

  # Was eine Freigabe NICHT verschafft. Beide Stellen lasen bisher jede
  # Vereinszugehoerigkeit statt nur die Heimat; erreichbar war das ueber den
  # mehrstufigen Antragsweg, seit der Lockerung oben mit einem Aufruf.
  test 'eine Freigabe verschafft dem fremden Verband keine Stammdatenhoheit' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }
    assert_response :success

    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))
    post '/api/v2/admin/players.json',
         params: { id: player.id, club_id: foreign[:club].id, first_name: 'Fremd',
                   last_name: player.last_name, birthdate: player.birthdate.to_s,
                   gender: player.gender, nation_id: player.nation_id },
         as: :json

    assert_response :forbidden
    assert_not_equal 'Fremd', player.reload.first_name,
                     'der Vorname darf sich durch den abgewiesenen Aufruf nicht aendern'
  end

  # Gegenprobe: Der Heimatverband darf die Stammdaten weiterhin pflegen.
  test 'der Heimatverband pflegt die Stammdaten weiter' do
    heimat = club_in(@go)
    player = create(:player, clubs: [{ 'club_id' => heimat.id, 'home_club' => true }])
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post '/api/v2/admin/players.json',
         params: { id: player.id, club_id: heimat.id, first_name: 'Neu',
                   last_name: player.last_name, birthdate: player.birthdate.to_s,
                   gender: player.gender, nation_id: player.nation_id },
         as: :json

    assert_response :success, response.body
    assert_equal 'Neu', player.reload.first_name
  end

  # Eine spielerweite Sperre blockiert ALLE Lizenzantraege, auch die im
  # Heimatverband. Der Kommentar an `sbk_may_suspend?` sagt ausdruecklich, eine
  # Freigabe duerfe dafuer nicht genuegen -- die Zustaendigkeitsabfrage las aber
  # jede Zugehoerigkeit.
  test 'eine Freigabe erlaubt dem fremden Verband keine spielerweite Sperre' do
    player = player_homed_in(@go)
    foreign = foreign_go_with_club
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/admin/players/#{player.id}/add_additional_club", params: { club_id: foreign[:club].id }
    assert_response :success

    login_as(create(:user, :sbk_scoped, game_operation_id: foreign[:go].id))
    assert_no_difference -> { PlayerSuspension.count } do
      post "/api/v2/admin/players/#{player.id}/suspensions",
           params: { valid_until: 3.months.from_now.to_date.iso8601, reason: 'Test' }, as: :json
    end

    assert_response :forbidden
  end

  test 'der Heimatverband darf weiterhin sperren' do
    player = player_homed_in(@go)
    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_difference -> { PlayerSuspension.count }, 1 do
      post "/api/v2/admin/players/#{player.id}/suspensions",
           params: { valid_until: 3.months.from_now.to_date.iso8601, reason: 'Test' }, as: :json
    end

    assert_response :success, response.body
  end

  private

  def club_in(game_operation)
    create(:club, game_operation: game_operation)
  end

  # Eigener Spieler statt einer geteilten Vorrichtung: Die Fabrik :club setzt ohne
  # `game_operation:` KEINEN Landesverband, main_game_operation_id bliebe nil und
  # der Verein damit ausserhalb jedes SBK-Scopes. Ein Test darauf prüfte den
  # Datenmangel, nicht die Regel.
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
