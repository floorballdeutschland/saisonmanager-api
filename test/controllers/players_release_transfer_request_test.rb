require 'test_helper'

# Eine Freigabe über das Spielerprofil (`add_additional_club`) schrieb nur nach
# players.clubs. Die Übersicht „Transferanträge" liest transfer_requests -- eine
# so erteilte Freigabe war dort nie zu sehen, obwohl sie fachlich dieselbe ist
# wie die über den Antragsweg erteilte (`TransferRequest#execute_release!`
# schreibt genau denselben clubs-Eintrag, führt aber einen Vorgang mit).
class PlayersReleaseTransferRequestTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @home_club = create(:club, game_operation: @go)
    @target = create(:club, game_operation: @go)
    @player = create(:player, clubs: [{ 'club_id' => @home_club.id, 'home_club' => true }])
    @admin = create(:user, :admin)
  end

  test 'Freigabe über das Spielerprofil legt einen abgeschlossenen Vorgang an' do
    login_as(@admin)

    assert_difference -> { TransferRequest.count }, 1 do
      freigabe_erteilen(@target)
    end
    assert_response :success

    tr = TransferRequest.last
    assert_equal @player.id, tr.player_id
    assert_equal @target.id, tr.requesting_club_id
    assert_equal @home_club.id, tr.former_club_id, 'abgebend ist der Heimatverein'
    assert_equal 'release', tr.request_type
    assert_equal 'approved', tr.status
    assert tr.direct, 'ohne Antragsweg erteilt, also wie die Direktzuweisung gekennzeichnet'
    assert_equal @admin.id, tr.created_by
    assert_equal @admin.id, tr.approved_by_lv_user_id
    assert_not_nil tr.lv_approved_at
    assert_equal 18, tr.season_id
    assert_nil tr.player_confirmation_token,
               'der Bestätigungslink gehört zu einem laufenden Antrag'
    assert_nil tr.approved_by_club_user_id,
               'einen Freigabeschritt des abgebenden Vereins hat es nicht gegeben'
  end

  test 'die Freigabe steht danach in der Übersicht der Transferanträge' do
    login_as(@admin)
    freigabe_erteilen(@target)

    get '/api/v2/admin/transfer_requests.json'

    assert_response :success
    eintrag = JSON.parse(response.body).find { |r| r['player']['id'] == @player.id }
    assert eintrag, 'die erteilte Freigabe fehlt in der Übersicht'
    assert_equal 'release', eintrag['request_type']
    assert_equal 'approved', eintrag['status']
    assert_equal @target.id, eintrag['requesting_club']['id']
  end

  # Der abgebende Verein ist Pflichtspalte des Vorgangs. Ohne gültige
  # Heimat-Zugehörigkeit gibt es keinen -- die Freigabe selbst darf daran nicht
  # scheitern, sonst nähme die Änderung genau den Altbestandsprofilen, die diese
  # Lücke haben, den einzigen Weg zu einer Freigabe (der Antragsweg weist sie
  # bereits ab).
  test 'ohne Heimatverein bleibt die Freigabe bestehen, nur ohne Vorgang' do
    ohne_heimat = create(:player, clubs: [])
    login_as(@admin)

    assert_no_difference -> { TransferRequest.count } do
      post "/api/v2/admin/players/#{ohne_heimat.id}/add_additional_club", params: { club_id: @target.id }
    end

    assert_response :success
    assert_includes ohne_heimat.reload.clubs.map { |c| c['club_id'] }, @target.id
  end

  # Gegenprobe zur Transaktion: Ein abgewiesener Aufruf darf weder Zugehörigkeit
  # noch Vorgang hinterlassen.
  test 'abgewiesene Freigabe legt keinen Vorgang an' do
    deaktiviert = create(:club, game_operation: @go, deactivated_at: Time.current)
    login_as(@admin)

    assert_no_difference -> { TransferRequest.count } do
      freigabe_erteilen(deaktiviert)
    end

    assert_response :unprocessable_entity
  end

  test 'wird die Freigabe im Spielerprofil beendet, wird der Vorgang widerrufen' do
    login_as(@admin)
    freigabe_erteilen(@target)
    tr = TransferRequest.last

    freigabe_beenden(@target, valid_until_of(@target))

    assert_response :success
    tr.reload
    assert_equal 'revoked', tr.status
    assert_equal @admin.id, tr.revoked_by
    assert_not_nil tr.revoked_at
    assert_equal 'Freigabe im Spielerprofil beendet', tr.revocation_reason
  end

  # `remove_additional_club` stempelt nur Einträge, deren `valid_until` mit dem
  # mitgeschickten Wert übereinstimmt. Passt es nicht, endet nichts -- und dann
  # darf auch nichts widerrufen werden.
  test 'ein folgenloser Aufruf widerruft keinen Vorgang' do
    login_as(@admin)
    freigabe_erteilen(@target)
    tr = TransferRequest.last

    freigabe_beenden(@target, '2030-01-01T00:00:00.000+01:00')

    assert_response :success
    assert_equal 'approved', tr.reload.status
  end

  # Der Widerruf muss GENAU die beendete Freigabe treffen. Eine regulaer am
  # Stichtag ausgelaufene Freigabe an denselben Verein bleibt bewusst auf
  # `approved` stehen -- der Widerruf darf sie nicht erwischen. Das ist nicht
  # bloss Anzeige: `League.license_release_dates` liest `release`+`approved` und
  # speist damit die Spalte „Freigabedatum" der Lizenzliste je Saison.
  test 'der Widerruf trifft nicht die Freigabe einer frueheren Saison' do
    alt = TransferRequest.create!(
      player_id: @player.id, requesting_club_id: @target.id, former_club_id: @home_club.id,
      status: 'approved', request_type: 'release', created_by: @admin.id,
      approved_by_lv_user_id: @admin.id, lv_approved_at: 14.months.ago, season_id: 17
    )

    login_as(@admin)
    freigabe_erteilen(@target)
    neu = TransferRequest.last
    assert_not_equal alt.id, neu.id, 'Vorbedingung: es sind zwei Vorgaenge'

    freigabe_beenden(@target, valid_until_of(@target))

    assert_response :success
    assert_equal 'revoked', neu.reload.status
    assert_equal 'approved', alt.reload.status,
                 'die Freigabe der frueheren Saison bleibt unberuehrt'
  end

  # Und wenn es zur beendeten Freigabe gar keinen Vorgang gibt (vor api#572
  # erteilt, vom Datenlauf uebersprungen), wird lieber nichts widerrufen als das
  # Falsche: Der alte Vorgang bleibt stehen, das ist der Zustand von vorher.
  test 'ohne passenden Vorgang wird nichts widerrufen' do
    alt = TransferRequest.create!(
      player_id: @player.id, requesting_club_id: @target.id, former_club_id: @home_club.id,
      status: 'approved', request_type: 'release', created_by: @admin.id,
      approved_by_lv_user_id: @admin.id, lv_approved_at: 14.months.ago, season_id: 17
    )
    # Freigabe von Hand, ohne Vorgang -- so sieht der Altbestand aus.
    @player.clubs += [{ 'club_id' => @target.id, 'home_club' => false, 'created_by' => @admin.id,
                        'created_at' => 2.days.ago.iso8601,
                        'valid_until' => 1.year.from_now.iso8601 }]
    @player.save!(validate: false)

    login_as(@admin)
    freigabe_beenden(@target, valid_until_of(@target))

    assert_response :success
    assert_equal 'approved', alt.reload.status
  end

  # Die Vorgangszeile ist die Zugabe, nicht der Zweck: Eine fehlende
  # Saison-Konfiguration darf die Freigabe nicht scheitern lassen.
  # `transfer_requests.season_id` ist NOT NULL ohne Validierung, ein nil kaeme
  # sonst als 500 heraus und rollte die Zugehoerigkeit mit zurueck.
  test 'ohne laufende Saison bleibt die Freigabe bestehen, nur ohne Vorgang' do
    Setting.stub(:current_season_id, nil) do
      login_as(@admin)
      assert_no_difference -> { TransferRequest.count } do
        freigabe_erteilen(@target)
      end
    end

    assert_response :success
    assert_includes @player.reload.clubs.map { |c| c['club_id'] }, @target.id
  end

  private

  def freigabe_erteilen(club)
    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: club.id }
  end

  def freigabe_beenden(club, valid_until)
    post "/api/v2/admin/players/#{@player.id}/remove_additional_club",
         params: { club_id: club.id, valid_until: }
  end

  def valid_until_of(club)
    @player.reload.clubs.find { |c| c['club_id'] == club.id && !c['home_club'] }['valid_until']
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end
end
