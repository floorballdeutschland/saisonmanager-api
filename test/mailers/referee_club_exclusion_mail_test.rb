require 'test_helper'

# Anträge zur Vereins-Ausschlussliste entscheidet die Ansetzung von Floorball
# Deutschland. Die Mails dürfen deshalb nicht mehr beim Landesverband landen,
# der sie in keiner Maske sieht.
class RefereeClubExclusionMailTest < ActionMailer::TestCase
  setup do
    @state_association = create(:state_association, rsk_email: 'ansetzung@lv.example')
    @club = create(:club, name: 'Eigener Verein', state_association: @state_association)
    @other_club = create(:club, name: 'Anderer Verein', state_association: @state_association)
    @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel',
                                email: 'schiri@example.de', club: @club)
  end

  test 'Antrag geht an das zentrale Ansetzungs-Postfach und nicht an den Landesverband' do
    mail = RefereeMailer.club_exclusion_requested(exclusion_request)

    empfaenger = Array(mail.to) + Array(mail.cc) + Array(mail.bcc)
    assert_equal ['sr-ansetzungen@floorball.de'], empfaenger
  end

  test 'Rueckfragen zum Antrag gehen an den Schiri, ersatzweise an das zentrale Postfach' do
    assert_equal ['schiri@example.de'], RefereeMailer.club_exclusion_requested(exclusion_request).reply_to

    @referee.update!(email: nil)
    assert_equal ['sr-ansetzungen@floorball.de'], RefereeMailer.club_exclusion_requested(exclusion_request).reply_to
  end

  test 'Entscheidung antwortet an die entscheidende Stelle statt an den Landesverband' do
    request = exclusion_request
    request.update!(status: 'approved')
    mail = RefereeMailer.club_exclusion_decision(request)

    assert_equal ['schiri@example.de'], mail.to
    assert_equal ['sr-ansetzungen@floorball.de'], mail.reply_to
  end

  private

  def exclusion_request
    @exclusion_request ||= RefereeClubExclusionRequest.create!(
      referee: @referee, club: @other_club, kind: 'add', reason: 'Tochter spielt dort'
    )
  end
end
