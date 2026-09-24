require 'test_helper'
require_relative 'transfer_request_test_helpers'

# Direktzuweisung mit Wunschdatum: Der Verband legt den Vollzugstag fest, und
# rake transfers:execute_scheduled vollzieht am Stichtag (siehe
# test/lib/tasks/execute_scheduled_transfers_test.rb). Eigene Klasse, weil
# TransferRequestsControllerTest an der ClassLength-Grenze steht.
module Admin
  class TransferRequestsDirectAssignScheduledTest < ActionDispatch::IntegrationTest
    include TransferRequestTestHelpers

    setup { setup_transfer_request_world }

    def home_club_id
      @player.reload.clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }&.dig('club_id')
    end

    def direct_assign(**extra)
      post '/api/v2/admin/transfer_requests/direct_assign', params: {
        player_id: @player.id, requesting_club_id: @requesting_club.id, **extra
      }
    end

    test 'Wunschdatum in der Zukunft plant den Transfer statt ihn zu vollziehen' do
      termin = Date.today + 3
      login(@sbk)
      # Die Ankuendigung, getrennt an Vereinspostfaecher und Person.
      assert_emails 2 do
        direct_assign(effective_date: termin.iso8601)
      end
      assert_response :created

      body = JSON.parse(response.body)
      assert_equal 'scheduled', body['status']
      assert_equal true, body['direct']
      assert_equal termin.iso8601, body['effective_date']

      tr = TransferRequest.find(body['id'])
      assert_equal @sbk.id, tr.approved_by_lv_user_id
      assert_not_nil tr.lv_approved_at
      assert_equal @former_club.id, home_club_id, 'bis zum Stichtag bleibt der Spieler im abgebenden Verein'

      ActionMailer::Base.deliveries.last(2).each do |mail|
        assert_includes mail.subject, "Vollzug am #{termin.strftime('%d.%m.%Y')}"
        assert_includes mail.body.decoded, 'direkt zugewiesen'
      end
    end

    # Anders als im Antrag des Vereins gilt keine Mindestfrist von 7 Tagen:
    # Die Direktzuweisung ist der Weg fuer Sonderfaelle.
    test 'Wunschdatum morgen ist erlaubt' do
      login(@admin)
      direct_assign(effective_date: (Date.today + 1).iso8601)
      assert_response :created
      assert_equal 'scheduled', JSON.parse(response.body)['status']
    end

    test 'Wunschdatum heute vollzieht sofort' do
      login(@sbk)
      direct_assign(effective_date: Date.today.iso8601)
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'approved', body['status']
      assert_nil body['effective_date']
      assert_equal @requesting_club.id, home_club_id
    end

    # 25.09. 01:00 deutscher Zeit ist auf dem Server noch der 24.09. (UTC).
    # Die Maske bietet dann den 25.09. als heute an, und so muss ihn auch die
    # API lesen: sofort vollziehen, nicht planen.
    test 'heute zaehlt nach deutscher Zeit, nicht nach der Serverzeit' do
      travel_to Time.utc(2026, 9, 24, 23, 0) do
        login(@sbk)
        direct_assign(effective_date: '2026-09-25')
        assert_response :created
        assert_equal 'approved', JSON.parse(response.body)['status']
      end
    end

    test 'leeres Wunschdatum vollzieht sofort wie bisher' do
      login(@sbk)
      direct_assign(effective_date: '')
      assert_response :created
      assert_equal 'approved', JSON.parse(response.body)['status']
    end

    test 'Wunschdatum in der Vergangenheit → 422, nichts angelegt' do
      login(@sbk)
      assert_no_emails do
        direct_assign(effective_date: (Date.today - 1).iso8601)
      end
      assert_response :unprocessable_entity
      assert_match(/Vergangenheit/, JSON.parse(response.body)['error'])
      assert_equal 0, TransferRequest.where(player_id: @player.id).count
      assert_equal @former_club.id, home_club_id
    end

    test 'Wunschdatum nicht im ISO-Format → 422' do
      login(@sbk)
      direct_assign(effective_date: '01.07.2027')
      assert_response :unprocessable_entity
      assert_equal 0, TransferRequest.where(player_id: @player.id).count
    end

    # Der geplante Vorgang zaehlt als laufender Transfer: Eine zweite
    # Zuweisung desselben Spielers wird abgewiesen, bis er annulliert ist.
    test 'geplanter Transfer sperrt eine weitere Direktzuweisung' do
      login(@sbk)
      direct_assign(effective_date: (Date.today + 5).iso8601)
      assert_response :created

      direct_assign
      assert_response :unprocessable_entity
      assert_match(/bereits ein Transfer aktiv/, JSON.parse(response.body)['error'])
    end

    test 'geplante Direktzuweisung laesst sich annullieren' do
      login(@sbk)
      direct_assign(effective_date: (Date.today + 5).iso8601)
      tr_id = JSON.parse(response.body)['id']

      patch "/api/v2/admin/transfer_requests/#{tr_id}/cancel"
      assert_response :success
      assert_equal 'withdrawn', TransferRequest.find(tr_id).status
      assert_equal @former_club.id, home_club_id
    end
  end
end
