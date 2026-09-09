require 'test_helper'
require_relative 'transfer_request_test_helpers'

# Beide Transferlisten zeigen standardmaessig nur die laufende Saison (#640).
#
# Vorher kannte keine der beiden einen Saisonbezug, und der Saisonwechsel fasst
# `transfer_requests` nicht an -- er schreibt nur `current_season_id` in die
# Einstellungen. Nach dem ersten Wechsel waeren die Vorgaenge der Vorsaison
# stehen geblieben und die neuen obendrauf.
#
# Die Gegenprobe ist genauso wichtig wie der Filter: `all_seasons=true` muss
# alles liefern. Der Landesverband stellt seine Gebuehren fuer erteilte
# Freigaben am Saisonende, und der Beleg dafuer ist der Vorgang.
module Admin
  class TransferRequestSeasonScopeTest < ActionDispatch::IntegrationTest
    include TransferRequestTestHelpers

    setup do
      setup_transfer_request_world
    end

    # Ein abgeschlossener Vorgang der Vorsaison. Eigener Spieler je Aufruf, wie
    # in create_incoming_request und aus demselben Grund: Die partiellen
    # Unique-Indizes haengen am Spieler.
    def vorsaison_vorgang(former_club: nil)
      TransferRequest.create!(
        player: create(:player),
        requesting_club: @requesting_club,
        former_club: former_club || @former_club,
        status: 'approved',
        created_by: @vm_requesting.id,
        season_id: 17,
        lv_approved_at: 1.year.ago,
        request_type: 'transfer'
      )
    end

    test 'die Hauptliste zeigt nur die laufende Saison' do
      aktuell = create_transfer_request(status: 'approved')
      alt = vorsaison_vorgang
      login(@admin)

      get '/api/v2/admin/transfer_requests'
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_includes ids, aktuell.id
      assert_not_includes ids, alt.id
    end

    # Ohne diesen Weg waere die Vorsaison nicht mehr abrechenbar.
    test 'die Hauptliste liefert mit all_seasons auch die Vorsaison' do
      aktuell = create_transfer_request(status: 'approved')
      alt = vorsaison_vorgang
      login(@admin)

      get '/api/v2/admin/transfer_requests', params: { all_seasons: 'true' }
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_includes ids, aktuell.id
      assert_includes ids, alt.id
    end

    test 'die eingehende Liste zeigt nur die laufende Saison' do
      aktuell = create_incoming_request
      alt = incoming_vorsaison_vorgang
      login(@sbk)

      get '/api/v2/admin/transfer_requests/incoming'
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_includes ids, aktuell.id
      assert_not_includes ids, alt.id
    end

    test 'die eingehende Liste liefert mit all_seasons auch die Vorsaison' do
      aktuell = create_incoming_request
      alt = incoming_vorsaison_vorgang
      login(@sbk)

      get '/api/v2/admin/transfer_requests/incoming', params: { all_seasons: 'true' }
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_includes ids, aktuell.id
      assert_includes ids, alt.id
    end

    # Wie create_incoming_request, nur in der Vorsaison: aufnehmender Verein im
    # eigenen Spielbetrieb, abgebender ausserhalb.
    def incoming_vorsaison_vorgang
      vorsaison_vorgang(former_club: create_club_in_other_game_operation)
    end
  end
end
