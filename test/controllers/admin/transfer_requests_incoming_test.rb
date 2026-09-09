require 'test_helper'
require_relative 'transfer_request_test_helpers'

module Admin
  # GET /api/v2/admin/transfer_requests/incoming
  #
  # Eigene Datei und nicht bei den uebrigen Transferantrags-Tests: Jene Klasse
  # steht an der Grenze von Metrics/ClassLength (siehe
  # TransferRequestTestHelpers).
  class TransferRequestsIncomingTest < ActionDispatch::IntegrationTest
    include TransferRequestTestHelpers

    setup { setup_transfer_request_world }

    test 'SBK sieht den vollzogenen Transfer in einen Verein des eigenen Verbands' do
      tr = create_incoming_request
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      body = JSON.parse(response.body)
      ids = body.map { |row| row['id'] }
      assert_equal [tr.id], ids
      assert_equal @requesting_club.id, body.first['requesting_club']['id']
    end

    test 'auch die Freigabe steht in der Liste der eingehenden Vorgaenge' do
      tr = create_incoming_request(request_type: 'release')
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      body = JSON.parse(response.body)
      ids = body.map { |row| row['id'] }
      assert_equal [tr.id], ids
      assert_equal 'release', body.first['request_type']
    end

    test 'der beschlossene, aber noch nicht wirksame Transfer steht mit in der Liste' do
      tr = create_incoming_request(status: 'scheduled')
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      ids = JSON.parse(response.body).map { |row| row['id'] }
      assert_equal [tr.id], ids
    end

    # Ein Vorgang, der noch bei der abgebenden Seite liegt, gehoert nicht in eine
    # Ansicht ohne Handlungsmoeglichkeit: Der aufnehmende Landesverband koennte
    # daran nichts tun, die Zeile wuerde nur eine Zustaendigkeit suggerieren.
    test 'laufende und abgelehnte Vorgaenge bleiben aus der Liste heraus' do
      create_incoming_request(status: 'pending_club')
      create_incoming_request(status: 'pending_lv')
      create_incoming_request(status: 'rejected_by_club', request_type: 'release')
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    # Verbandsinterne Wechsel stehen bereits in der Hauptliste -- dort ueber den
    # abgebenden Verein. Hier waeren sie eine zweite Zeile fuer denselben
    # Vorgang.
    test 'verbandsinterner Transfer erscheint nicht unter den eingehenden' do
      create_incoming_request(former_club: @former_club)
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    test 'abgehender Transfer erscheint nicht unter den eingehenden' do
      create_incoming_request(
        former_club: @former_club, requesting_club: create_club_in_other_game_operation
      )
      login(@sbk)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    test 'SBK eines anderen Verbands sieht den eingehenden Vorgang nicht' do
      create_incoming_request
      other_club = create_club_in_other_game_operation
      other_go = GameOperation.find_by(state_association_id: other_club.state_association_id)
      login(create_user_sbk(game_operation_id: other_go.id))
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      assert_empty JSON.parse(response.body)
    end

    # Der Bundesverband ist fuer alle Vereine zustaendig, fuer ihn gibt es kein
    # „ausserhalb". Ein Ausschluss der eigenen Vereine liesse seine Liste immer
    # leer -- er bekommt deshalb alle abgeschlossenen Vorgaenge.
    test 'global gescopte SBK sieht auch den verbandsinternen Vorgang' do
      tr = create_incoming_request(former_club: @former_club)
      login(create_user_sbk(game_operation_id: 0))
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      ids = JSON.parse(response.body).map { |row| row['id'] }
      assert_equal [tr.id], ids
    end

    test 'Admin sieht die abgeschlossenen Vorgaenge, nicht die laufenden' do
      approved = create_incoming_request
      create_incoming_request(status: 'pending_club')
      login(@admin)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success
      ids = JSON.parse(response.body).map { |row| row['id'] }
      assert_equal [approved.id], ids
    end

    test 'Vereinsmanager bekommt die Liste der eingehenden Vorgaenge nicht' do
      create_incoming_request
      login(@vm_requesting)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :forbidden
    end

    test 'Teammanager bekommt die Liste der eingehenden Vorgaenge nicht' do
      login(@tm)
      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :forbidden
    end

    # Der Kern der Trennung: Die Ansicht ist Auskunft, keine Zustaendigkeit. Sie
    # darf dem aufnehmenden Landesverband nichts geben, was der abgebende
    # entscheidet -- sonst waere der Riegel aus #lv_authorized? ueber die neue
    # Liste umgangen.
    test 'die Sichtbarkeit verschafft keine Handlungsrechte am eingehenden Vorgang' do
      tr = create_incoming_request(request_type: 'release')
      login(@sbk)

      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :forbidden

      patch "/api/v2/admin/transfer_requests/#{tr.id}/revoke",
            params: { revocation_reason: 'Versuch' }
      assert_response :forbidden
      assert_equal 'approved', tr.reload.status
    end

    # Wie die Hauptliste darf die Uebersicht die Namen nicht je Zeile nachladen.
    test 'Liste der eingehenden Vorgaenge laedt die Konten nicht je Zeile nach' do
      create_incoming_request
      login(@sbk)

      with_one = count_user_queries { get '/api/v2/admin/transfer_requests/incoming' }
      assert_response :success
      assert_equal 1, JSON.parse(response.body).size

      create_incoming_request
      create_incoming_request

      with_three = count_user_queries { get '/api/v2/admin/transfer_requests/incoming' }
      assert_response :success
      assert_equal 3, JSON.parse(response.body).size
      assert_equal with_one, with_three,
                   'zusätzliche Zeilen dürfen keine zusätzliche User-Abfrage kosten ' \
                   "(#{with_one} bei einer, #{with_three} bei drei Zeilen)"
    end
  end
end
