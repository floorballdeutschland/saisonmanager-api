require 'test_helper'
require_relative 'transfer_request_test_helpers'

# Anschrift und Kontakt der beteiligten Vereine am abgeschlossenen
# Transfervorgang (#641).
#
# Der abgebende Landesverband stellt die Transferrechnung an den aufnehmenden
# Verein. Ohne dessen ladungsfaehige Anschrift kann er das nicht, und bisher
# stand sie nirgends: Am Verein gab es Name, Kuerzel, Name laut Vereinsregister,
# Bundesland und Kontakt-E-Mail.
#
# Eigene Datei und nicht im transfer_requests_controller_test: Die Testklasse
# dort steht dicht unter Metrics/ClassLength (Max 1000, siehe .rubocop_todo.yml),
# und ihr setup traegt Konten, die diese Faelle nicht brauchen.
module Admin
  class TransferRequestClubAddressesTest < ActionDispatch::IntegrationTest
    include TransferRequestTestHelpers

    setup do
      create(:setting, current_season_id: '18')
      @sa = create(:state_association, sbk_email: 'sbk@test.example')
      @go = create(:game_operation, state_association_id: @sa.id)

      @former_club = create(:club, game_operation: @go, long_name: 'Abgebender Verein e.V.',
                                   street: 'Herkunftsweg', house_number: '3',
                                   postcode: '30159', city: 'Hannover',
                                   contact_email: 'abgebend@test.example')
      @requesting_club = create(:club, game_operation: @go, long_name: 'Aufnehmender Verein e.V.',
                                       street: 'Zielweg', house_number: '12b',
                                       postcode: '20095', city: 'Hamburg',
                                       contact_email: 'aufnehmend@test.example')

      @player = create(:player, first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-15',
                                clubs: [{ 'club_id' => @former_club.id, 'home_club' => true }])

      @admin = create(:user, :admin)
      @sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
      @vm_requesting = create(:user, :vm, club_id: @requesting_club.id)
    end

    test 'abgeschlossener Vorgang liefert die Anschriften beider Vereine' do
      tr = create_transfer_request(status: 'approved')
      login(@sbk)

      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success

      anschriften = JSON.parse(response.body)['club_addresses']
      assert_equal 'Aufnehmender Verein e.V.', anschriften['requesting_club']['long_name']
      assert_equal %w[Zielweg 12b 20095 Hamburg],
                   anschriften['requesting_club'].values_at('street', 'house_number', 'postcode', 'city')
      assert_equal 'aufnehmend@test.example', anschriften['requesting_club']['contact_email']
      assert_equal %w[Herkunftsweg 3 30159 Hannover],
                   anschriften['former_club'].values_at('street', 'house_number', 'postcode', 'city')
    end

    # Wo nichts gepflegt ist, bleibt es leer -- es gibt keinen Datenlauf, der
    # den Bestand nachtraegt. Die Ansicht muss das aushalten, statt am fehlenden
    # Feld zu scheitern.
    test 'ungepflegte Anschrift kommt leer statt gar nicht' do
      @former_club.update!(long_name: nil, street: nil, house_number: nil,
                           postcode: nil, city: nil, contact_email: nil)
      tr = create_transfer_request(status: 'approved')
      login(@sbk)

      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success

      former = JSON.parse(response.body)['club_addresses']['former_club']
      assert former.key?('street')
      assert_nil former['street']
    end

    # Vor dem Vollzug gibt es keine Rechnung und damit keinen Anlass. "scheduled"
    # ist zwar vollstaendig genehmigt, aber noch nicht vollzogen -- erst
    # execute_transfer! setzt "approved".
    test 'nicht abgeschlossener Vorgang liefert die Anschriften nicht' do
      tr = create_transfer_request(status: 'pending_club')
      login(@admin)

      %w[pending_club pending_player pending_lv scheduled rejected_by_lv revoked].each do |status|
        tr.update_columns(status: status)

        get "/api/v2/admin/transfer_requests/#{tr.id}"
        assert_response :success
        assert_nil JSON.parse(response.body)['club_addresses'], "Status #{status}"
      end
    end

    # Kein eigenes Rechte-Gate: Wer den Vorgang sehen darf, ist Partei oder
    # zustaendiger Verband. Der aufnehmende Verein bekommt die Rechnung und muss
    # sie einordnen koennen.
    test 'Vereinsmanager des aufnehmenden Vereins sieht die Anschriften' do
      tr = create_transfer_request(status: 'approved')
      login(@vm_requesting)

      get "/api/v2/admin/transfer_requests/#{tr.id}"
      assert_response :success
      assert_equal 'Herkunftsweg',
                   JSON.parse(response.body)['club_addresses']['former_club']['street']
    end

    # Die Uebersicht rendert denselben Hash und zieht ueber jeden Vorgang, den
    # ein Konto sehen darf. Anschriften gehoeren in den einzelnen Vorgang, den
    # jemand geoeffnet hat.
    test 'Uebersicht traegt die Anschriften nicht' do
      create_transfer_request(status: 'approved')
      login(@admin)

      get '/api/v2/admin/transfer_requests'
      assert_response :success

      zeilen = JSON.parse(response.body)
      assert_equal 1, zeilen.size
      assert_not zeilen.first.key?('club_addresses')
    end
  end
end
