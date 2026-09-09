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

    # Der gefaehrlichste Fall des Filters. `scheduled` ist vollstaendig
    # genehmigt und wartet nur auf das Wirksamkeitsdatum -- `expirable` faengt
    # ihn ausdruecklich NICHT ab, und `effective_date` hat keine Obergrenze.
    # Faellt so eine Zeile beim Saisonwechsel aus der Liste, ist der
    # "Vollziehen"-Knopf nur noch ueber eine URL erreichbar, auf die nichts
    # verlinkt: Der Wechsel findet nie statt, ohne Mail und ohne Logeintrag.
    test 'ein terminierter Vorgang der Vorsaison bleibt sichtbar' do
      terminiert = vorsaison_vorgang
      terminiert.update_columns(status: 'scheduled', effective_date: 1.month.from_now.to_date)
      login(@admin)

      get '/api/v2/admin/transfer_requests'
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_includes ids, terminiert.id,
                      'ein offener Vorgang darf nie hinter dem Saisonfilter verschwinden'
    end

    # Gilt fuer jeden offenen Status, nicht nur fuer scheduled: Die
    # pending-Fristen haengen an einem Cron, der eingetragen sein muss.
    test 'offene Antraege der Vorsaison bleiben in jedem Status sichtbar' do
      login(@admin)

      TransferRequest::ACTIVE_STATUSES.each do |status|
        offen = vorsaison_vorgang
        offen.update_columns(status: status)

        get '/api/v2/admin/transfer_requests'
        assert_response :success

        ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
        assert_includes ids, offen.id, "Status #{status}"
      end
    end

    # Gegenprobe: Der Filter greift weiterhin fuer abgeschlossene Vorgaenge.
    # Ohne sie liesse sich die Ausnahme auf alle Status ausweiten, ohne dass
    # ein Test faellt.
    test 'ein abgeschlossener Vorgang der Vorsaison bleibt ausgeblendet' do
      abgeschlossen = vorsaison_vorgang
      abgeschlossen.update_columns(status: 'withdrawn')
      login(@admin)

      get '/api/v2/admin/transfer_requests'
      assert_response :success

      ids = JSON.parse(response.body).map { |zeile| zeile['id'] }
      assert_not_includes ids, abgeschlossen.id
    end

    # Wie create_incoming_request, nur in der Vorsaison: aufnehmender Verein im
    # eigenen Spielbetrieb, abgebender ausserhalb.
    def incoming_vorsaison_vorgang
      vorsaison_vorgang(former_club: create_club_in_other_game_operation)
    end
  end
end
