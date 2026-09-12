require 'test_helper'

# Das Zurücksetzen einer erteilten Lizenz auf `beantragt` durch den Verband
# (License::REQUESTED über handle_license_request), für den Fall "erteilt,
# obwohl noch etwas fehlte". Die Regel dahinter steht in License.resettable? /
# .reset_blocked_reason.
#
# Der Endpunkt nahm den Zielstatus `beantragt` schon vorher an – bisher aber nur
# über den Widerruf einer Ablehnung, ohne Pflicht-Freitext. Dieser Weg muss
# unberührt bleiben, dafür sorgt hier ein eigener Test.
#
# Eigene Datei, weil players_controller_test.rb nahe an Metrics/ClassLength
# (Max 1000, .rubocop_todo.yml) liegt.
class PlayersLicenseResetTest < ActionDispatch::IntegrationTest
  REASON = 'Spielerpass fehlte, Erteilung war zu früh'.freeze

  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # Eine Lizenz mit dem Verlauf "beantragt -> erteilt", also der Normalfall, den
  # der Verband zurücksetzen können soll. Das Gültigkeitsdatum stammt aus der
  # Erteilung und steht deshalb mit drin.
  def approved_license(season_id: @league.season_id, extra: {})
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'valid_until' => 1.year.from_now.iso8601,
                                 'history' => [
                                   { 'license_status_id' => License::REQUESTED,
                                     'created_at' => 3.days.ago.iso8601, 'created_by' => nil },
                                   { 'license_status_id' => License::APPROVED,
                                     'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
                                 ] }.merge(extra)])
    id
  end

  def reset_license(license_id, reason: REASON)
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::REQUESTED, reason: reason },
         as: :json
  end

  def current_entry
    @player.reload.licenses.first['history'].max_by { |h| h['created_at'] }
  end

  # --- Der gewollte Weg -----------------------------------------------------

  test 'SBK setzt eine erteilte Lizenz mit Begründung auf beantragt zurück' do
    license_id = approved_license
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    login_as(sbk)

    reset_license(license_id)

    assert_response :ok
    entry = current_entry
    assert_equal License::REQUESTED, entry['license_status_id'].to_i
    assert_equal REASON, entry['reason']
    assert_equal sbk.id, entry['created_by']
  end

  # Die frühere Erteilung bleibt in der History stehen. Daran hängt die
  # Gebührenrechnung, die jede Lizenz der Saison mitsamt Verlauf exportiert:
  # Zurücksetzen darf kein Weg an der Gebühr vorbei sein.
  test 'Zurücksetzen hängt an, überschreibt nichts' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id)

    history = @player.reload.licenses.first['history']
    assert_equal([License::REQUESTED, License::APPROVED, License::REQUESTED],
                 history.map { |h| h['license_status_id'].to_i })
  end

  # Der neue `beantragt`-Eintrag ist als Verwaltungskorrektur markiert und
  # startet die Karenzzeit deshalb nicht neu (License.grace_period_anchor).
  # Ohne die Markierung öffnete jedes Zurücksetzen dem Verein ein neues
  # Gratis-Fenster, und ein Zurückziehen darin löschte die Lizenz ersatzlos –
  # samt der Erteilung, die sie kostenpflichtig macht.
  test 'Zurücksetzen eröffnet dem Verein kein neues Gratis-Fenster' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    reset_license(license_id)
    assert_response :ok
    assert @player.reload.licenses.first['history'].last[License::REVOKED_REJECTION_KEY],
           'der Eintrag muss als Verwaltungskorrektur markiert sein'

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id }, as: :json

    assert_response :ok
    assert_not JSON.parse(response.body)['grace_period_deletion'],
               'das Zurückziehen darf die Lizenz nicht ersatzlos löschen'
    assert_equal 1, @player.reload.licenses.size
    assert_equal License::WITHDRAWN, current_entry['license_status_id'].to_i
  end

  # Das Gültigkeitsdatum stammt aus der Erteilung, die hiermit zurückgenommen
  # wird. Bliebe es stehen, meldete die Lizenzliste des Spielsekretariats für
  # einen offenen Antrag weiter ein "gültig bis".
  test 'das Gültigkeitsdatum der Erteilung wird geleert' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id)

    assert_response :ok
    assert_nil @player.reload.licenses.first['valid_until']
  end

  # Anders als beim Löschen: `beantragt` gehört weiter zum laufenden Wettbewerb
  # (License::ACTIVE_STATUSES), die Zuordnung bleibt also gültig. Sie
  # abzuräumen kostete den Verband den zweiten Tausch der Saison
  # (Player::GF_ROLE_SWAP_LIMIT), nur um denselben Stand wiederherzustellen.
  test 'die Erst-/Zweitlizenz-Zuordnung bleibt beim Zurücksetzen erhalten' do
    license_id = approved_license(extra: { 'gf_role' => 'erstlizenz' })
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id)

    assert_response :ok
    assert_equal 'erstlizenz', @player.reload.licenses.first['gf_role']
  end

  # --- Die Pflicht-Begründung ----------------------------------------------

  test 'ohne Begründung wird nicht zurückgesetzt' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id, reason: '')

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # `blank?` allein liefe hier vorbei: Ein Freitext aus lauter Leerzeichen ist
  # `present?` und stünde als leere Begründung in der Vereinsansicht.
  test 'eine Begründung aus Leerzeichen zählt nicht als Begründung' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id, reason: "   \n\t ")

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # Der Widerruf einer Ablehnung ist derselbe Statuswechsel über denselben
  # Endpunkt, kommt aber aus der Lizenzübersicht und schickt einen festen Text
  # statt einer Eingabe des Nutzers. Die neue Pflicht-Begründung darf ihn nicht
  # mitnehmen: Sonst wäre eine versehentliche Ablehnung wieder endgültig.
  test 'der Widerruf einer Ablehnung bleibt ohne Begründung möglich' do
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'history' => [
                                   { 'license_status_id' => License::REQUESTED,
                                     'created_at' => 3.days.ago.iso8601 },
                                   { 'license_status_id' => License::DENIED,
                                     'created_at' => 2.days.ago.iso8601 }
                                 ] }])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(id, reason: '')

    assert_response :ok
    assert_equal License::REQUESTED, current_entry['license_status_id'].to_i
  end

  # --- Die Grenzen der Regel ------------------------------------------------

  test 'eine Lizenz aus einer vergangenen Saison lässt sich nicht zurücksetzen' do
    license_id = approved_license(season_id: '17')
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id)

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # Der Altbestand aus dem Legacy-Import trägt gar keine season_id. Er darf
  # nicht versehentlich als "laufende Saison" durchgehen.
  test 'eine Lizenz ohne season_id lässt sich nicht zurücksetzen' do
    license_id = approved_license(season_id: nil)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    reset_license(license_id)

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # Der Status hängt an einer Sperre mit Laufzeit (Player#lift_suspension!
  # schreibt sie zurück). Der Knopf darf dort nicht stehen, sonst hätte der
  # Verband die laufende Sperre mit einem Klick aus der Lizenz herausgeschrieben.
  test 'reset_allowed ist bei einer gesperrten Lizenz false' do
    approved_license
    lizenzen = @player.licenses.deep_dup
    lizenzen.first['history'] << { 'license_status_id' => License::SUSPENDED,
                                   'created_at' => 1.hour.ago.iso8601 }
    @player.update!(licenses: lizenzen)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    get "/api/v2/admin/players/#{@player.id}.json"

    assert_response :success
    assert_equal false, JSON.parse(response.body)['licenses'].first['reset_allowed']
  end

  # --- Wer darf --------------------------------------------------------------

  test 'SBK eines fremden Spielbetriebs darf nicht zurücksetzen' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    reset_license(license_id)

    assert_response :forbidden
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  test 'der Vereinsmanager darf nicht zurücksetzen' do
    license_id = approved_license
    login_as(create(:user, :vm, club_id: @club.id))

    reset_license(license_id)

    assert_response :forbidden
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # --- Das Kennzeichen für den Knopf ----------------------------------------

  # `reset_allowed` je Lizenz, damit die Maske die Regel nicht nachbaut. Die
  # eigene Lizenz ja, die des fremden Verbandes nein – und beides im selben
  # Profil, denn genau so tritt der Fall auf: Eine Landes-SBK sieht das Profil
  # ihres Heimatspielers, der zusätzlich eine Lizenz in einem Bundesliga-Team
  # eines anderen Spielbetriebs hält.
  test 'reset_allowed folgt dem Verbands-Scope je Lizenz' do
    fremder_verband = create(:game_operation)
    fremde_liga = create(:league, :current_season, game_operation: fremder_verband)
    fremdes_team = create(:team, league: fremde_liga, club: create(:club, game_operation: fremder_verband))

    eigene_id = Digest::UUID.uuid_v4
    fremde_id = Digest::UUID.uuid_v4
    verlauf = [{ 'license_status_id' => License::APPROVED,
                 'created_at' => 2.days.ago.iso8601, 'created_by' => nil }]
    @player.update!(licenses: [
      { 'id' => eigene_id, 'team_id' => @team.id,
        'season_id' => @league.season_id, 'history' => verlauf },
      { 'id' => fremde_id, 'team_id' => fremdes_team.id,
        'season_id' => fremde_liga.season_id, 'history' => verlauf }
    ])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    get "/api/v2/admin/players/#{@player.id}.json"

    assert_response :success
    nach_id = JSON.parse(response.body)['licenses'].index_by { |l| l['id'] }
    assert_equal true, nach_id[eigene_id]['reset_allowed'],
                 'die eigene Lizenz muss zurücksetzbar bleiben'
    assert_equal false, nach_id[fremde_id]['reset_allowed'],
                 'der Knopf darf bei einem fremden Verband gar nicht erst erscheinen'
  end

  # Eine beantragte Lizenz ist schon dort, wo das Zurücksetzen sie hinbringen
  # würde. Der Knopf hätte keine Wirkung und darf nicht stehen.
  test 'reset_allowed ist bei einer beantragten Lizenz false' do
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'history' => [{ 'license_status_id' => License::REQUESTED,
                                                 'created_at' => 1.day.ago.iso8601 }] }])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    get "/api/v2/admin/players/#{@player.id}.json"

    assert_response :success
    assert_equal false, JSON.parse(response.body)['licenses'].first['reset_allowed']
  end
end
