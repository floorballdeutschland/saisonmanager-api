require 'test_helper'

# api#528: Seit api#512 weist der Transferprozess einen deaktivierten
# aufnehmenden Verein an jedem Schritt ab. Ein Antrag AUF einen gerade
# deaktivierten Verein blieb damit unerfuellbar stehen, und weil
# `TransferRequest.active` genau die vier laufenden Status abdeckt und in
# #create geprueft wird, blockierte er jeden neuen Antrag desselben Spielers.
#
# Club#deactivate! beendet die Antraege deshalb selbst, mit Mail an den Spieler
# und den abgebenden Verein.
class ClubDeactivationTransfersTest < ActiveSupport::TestCase
  # In einem Modelltest nicht automatisch dabei, anders als in den
  # Integrationstests.
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@test.example')
    @go = create(:game_operation, state_association_id: @sa.id)
    @former_club = create(:club, game_operation: @go, contact_email: 'abgebend@test.example')
    @requesting_club = create(:club, game_operation: @go, contact_email: 'aufnehmend@test.example')
    @player = create(:player, email: 'spieler@test.example',
                              clubs: [{ 'club_id' => @former_club.id, 'home_club' => true }])
    @admin = create(:user, :admin)
  end

  TransferRequest::STATUSES.each do |status|
    laufend = %w[pending_club pending_player pending_lv scheduled].include?(status)

    test "Deaktivierung #{laufend ? 'beendet' : 'laesst'} einen Antrag im Status #{status} #{laufend ? '' : 'unberuehrt'}" do
      tr = transfer_request(status: status)

      @requesting_club.deactivate!(@admin.id)

      assert_equal(laufend ? 'withdrawn' : status, tr.reload.status)
    end
  end

  test 'der beendete Antrag hat keinen Bestaetigungs-Token mehr' do
    tr = transfer_request(status: 'pending_player')

    @requesting_club.deactivate!(@admin.id)

    assert_nil tr.reload.player_confirmation_token
  end

  # Eine Freigabe legt ueber add_secondary_club_membership! ebenfalls eine
  # Mitgliedschaft im aufnehmenden Verein an.
  test 'eine Freigabe wird genauso beendet' do
    tr = transfer_request(status: 'pending_lv', request_type: 'release')

    @requesting_club.deactivate!(@admin.id)

    assert_equal 'withdrawn', tr.reload.status
  end

  # Gegenrichtung, und die fachliche Regel: Ein aufgeloester Verein gibt seine
  # Spieler gerade ab, seine eigenen Antraege laufen weiter.
  test 'ein Antrag AUS dem deaktivierten Verein bleibt stehen' do
    tr = TransferRequest.create!(
      player: @player, requesting_club: @requesting_club, former_club: @former_club,
      status: 'pending_lv', request_type: 'transfer', created_by: @admin.id,
      season_id: Setting.current_season_id
    )

    @former_club.deactivate!(@admin.id)

    assert_equal 'pending_lv', tr.reload.status
  end

  test 'ein Antrag auf einen anderen Verein bleibt stehen' do
    anderer = create(:club, game_operation: @go)
    tr = TransferRequest.create!(
      player: @player, requesting_club: anderer, former_club: @former_club,
      status: 'pending_lv', request_type: 'transfer', created_by: @admin.id,
      season_id: Setting.current_season_id
    )

    @requesting_club.deactivate!(@admin.id)

    assert_equal 'pending_lv', tr.reload.status
  end

  # Der Kern des Issues: Danach ist der Spieler wieder antragsfaehig.
  test 'nach der Deaktivierung ist der Spieler nicht mehr blockiert' do
    transfer_request(status: 'pending_lv')
    assert TransferRequest.active.where(player_id: @player.id).exists?,
           'Vorbedingung: der Antrag blockiert'

    @requesting_club.deactivate!(@admin.id)

    assert_not TransferRequest.active.where(player_id: @player.id).exists?
  end

  test 'die Mail geht an den Spieler und den abgebenden Verein' do
    transfer_request(status: 'pending_lv')

    assert_enqueued_emails 1 do
      @requesting_club.deactivate!(@admin.id)
    end
    perform_enqueued_jobs

    mail = ActionMailer::Base.deliveries.last
    assert_equal %w[spieler@test.example abgebend@test.example].sort, mail.to.sort
    assert_includes mail.subject, 'Transferantrag beendet'
    assert_includes mail.body.to_s, @requesting_club.name
  end

  test 'die Freigabe-Mail nennt den Antrag beim richtigen Namen' do
    transfer_request(status: 'pending_lv', request_type: 'release')

    @requesting_club.deactivate!(@admin.id)
    perform_enqueued_jobs

    assert_includes ActionMailer::Base.deliveries.last.subject, 'Spielerfreigabe-Antrag beendet'
  end

  test 'ohne beendete Antraege geht keine Mail raus' do
    assert_no_enqueued_emails do
      @requesting_club.deactivate!(@admin.id)
    end
  end

  # Ohne hinterlegte Adressen faellt die Mail aus, die Deaktivierung laeuft
  # trotzdem durch (gleiches Muster wie in den uebrigen Mailer-Methoden).
  test 'ohne Empfaenger bleibt der Antrag trotzdem beendet' do
    @player.update!(email: nil)
    @former_club.update!(contact_email: nil)
    tr = transfer_request(status: 'pending_lv')

    @requesting_club.deactivate!(@admin.id)

    assert_equal 'withdrawn', tr.reload.status
  end

  private

  def transfer_request(status:, request_type: 'transfer')
    TransferRequest.create!(
      player: @player, requesting_club: @requesting_club, former_club: @former_club,
      status: status, request_type: request_type, created_by: @admin.id,
      season_id: Setting.current_season_id,
      rejection_reason: status.start_with?('rejected') ? 'Grund' : nil,
      revocation_reason: status == 'revoked' ? 'Grund' : nil
    )
  end
end
