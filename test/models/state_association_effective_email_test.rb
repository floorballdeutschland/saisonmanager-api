require 'test_helper'

# Postfächer eines untergeordneten Landesverbands fallen auf den übergeordneten
# Verbund zurück (analog effective_rsk_email). Die Verbandsmaske sperrt die
# Felder bei einem Kind-LV und weist sie als „geerbt" aus; ohne Rückfall im
# Modell liefen vereinsbezogene Mails ins Leere, weil sie die Adresse direkt am
# Kind-Datensatz lesen (z. B. former_club.state_association bei Transfers).
class StateAssociationEffectiveEmailTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')

    @verbund = create(:state_association,
                      vsk_email: 'vsk@verbund.example.com',
                      sbk_email: 'sbk@verbund.example.com')
    @child = create(:state_association, parent: @verbund)
  end

  test 'Kind-LV ohne eigene Postfächer erbt die des Verbunds' do
    assert_equal 'vsk@verbund.example.com', @child.effective_vsk_email
    assert_equal 'sbk@verbund.example.com', @child.effective_sbk_email
  end

  test 'eigenes Postfach des Kind-LV hat Vorrang' do
    @child.update!(sbk_email: 'sbk@kind.example.com')

    assert_equal 'sbk@kind.example.com', @child.effective_sbk_email
    assert_equal 'vsk@verbund.example.com', @child.effective_vsk_email
  end

  test 'leerer String zaehlt nicht als eigenes Postfach' do
    @child.update!(vsk_email: '', sbk_email: '')

    assert_equal 'vsk@verbund.example.com', @child.effective_vsk_email
    assert_equal 'sbk@verbund.example.com', @child.effective_sbk_email
  end

  test 'ohne Verbund und ohne eigenen Eintrag bleibt das Postfach leer' do
    solo = create(:state_association)

    assert_nil solo.effective_vsk_email
    assert_nil solo.effective_sbk_email
  end

  test 'Verbund erbt nicht von seinen Kindern' do
    @verbund.update!(vsk_email: nil, sbk_email: nil)
    @child.update!(vsk_email: 'vsk@kind.example.com', sbk_email: 'sbk@kind.example.com')

    assert_nil @verbund.reload.effective_vsk_email
    assert_nil @verbund.effective_sbk_email
  end

  test 'full_hash liefert neben dem eigenen auch den effektiven Wert' do
    hash = @child.full_hash

    assert_nil hash[:sbk_email]
    assert_equal 'sbk@verbund.example.com', hash[:effective_sbk_email]
    assert_equal 'vsk@verbund.example.com', hash[:effective_vsk_email]
  end

  # Verdrahtung an einer echten Aufrufstelle: Der abgebende Verein hängt am
  # Kind-LV, die Genehmigungs-Mail muss trotzdem im SBK-Postfach des Verbunds
  # landen (vorher: früher return, keine Mail).
  test 'Transferbenachrichtigung erreicht die SBK des Verbunds' do
    former_club = create(:club, state_association: @child, contact_email: 'verein@example.com')
    requesting_club = create(:club, state_association: @child, contact_email: 'neuer-verein@example.com')
    player = create(:player)
    transfer_request = TransferRequest.create!(
      player: player,
      former_club: former_club,
      requesting_club: requesting_club,
      status: 'pending_lv',
      season_id: 18,
      created_by: 1
    )

    mail = TransferRequestMailer.pending_lv_notification(transfer_request)

    assert_equal ['sbk@verbund.example.com'], mail.to
  end
end
