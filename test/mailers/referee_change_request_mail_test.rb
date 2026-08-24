require 'test_helper'

# Korrekturanträge entscheidet die RSK des Landesverbands, in dem der Verein des
# Schiris liegt. Dorthin geht die Mail.
class RefereeChangeRequestMailTest < ActionMailer::TestCase
  setup do
    @lv = create(:state_association, rsk_email: 'rsk@lv.example')
    @club = create(:club, name: 'Eigener Verein', state_association: @lv)
    @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel',
                                club: @club, email: 'schiri@example.de')
  end

  test 'Antrag geht an das RSK-Postfach des Landesverbands' do
    mail = RefereeMailer.change_requested(change_request)

    assert_equal ['rsk@lv.example'], mail.to
    assert_equal ['schiri@example.de'], mail.reply_to
    assert_includes mail.body.encoded, 'Musterfrau'
  end

  test 'ohne Verband greift die zentrale RSK-Adresse' do
    @referee.update!(club: nil)

    assert_equal ['rsk@floorball.de'], RefereeMailer.change_requested(change_request).to
  end

  test 'untergeordneter Verband erbt das Postfach des Verbunds' do
    kind_lv = create(:state_association, rsk_email: nil, parent: @lv)
    @referee.update!(club: create(:club, state_association: kind_lv))

    assert_equal ['rsk@lv.example'], RefereeMailer.change_requested(change_request).to
  end

  test 'Entscheidung geht an den Schiri und gruesst mit dem Vornamen' do
    request = change_request
    request.approve!(1)
    mail = RefereeMailer.change_decision(request.reload)

    assert_equal ['schiri@example.de'], mail.to
    assert_equal ['rsk@lv.example'], mail.reply_to
    assert_includes mail.body.encoded, 'Hallo Anna,'
  end

  private

  def change_request
    @change_request ||= RefereeChangeRequest.create!(
      referee: @referee, correction_type: 'nachname', new_value: 'Musterfrau'
    )
  end
end
