require 'test_helper'

# Die Vorgangsmails sprachen von „dem Spieler", auch wenn am Profil „W"
# hinterlegt war. Geprueft wird hier der gerenderte Text, nicht der Helfer:
# Eine Vorlage, die den Helfer an einer Stelle nicht aufruft, faellt sonst
# durch nichts auf -- sie liest sich weiterhin fehlerfrei.
class TransferRequestGenderedWordingTest < ActionMailer::TestCase
  setup do
    @state_association = create(:state_association)
    @requesting_club = Club.create!(name: 'Neuer Verein', short_name: 'NV',
                                    contact_email: 'neuer@example.de',
                                    state_association_id: @state_association.id)
    @former_club = Club.create!(name: 'Alter Verein', short_name: 'AV',
                                contact_email: 'alter@example.de',
                                state_association_id: @state_association.id)
    @user = create(:user, :admin)
    create(:setting, current_season_id: '18')
  end

  def player(gender)
    create(:player, first_name: 'Charlie', last_name: 'Beispiel', gender: gender,
                    email: 'charlie@example.de',
                    clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }])
  end

  def transfer_request(gender, attrs = {})
    TransferRequest.create!({
      player: player(gender),
      requesting_club: @requesting_club,
      former_club: @former_club,
      created_by: @user.id,
      season_id: 18,
      request_type: 'transfer'
    }.merge(attrs))
  end

  def body_of(mail)
    (mail.html_part || mail).body.decoded
  end

  test 'der vollzogene Transfer nennt eine Spielerin als Spielerin' do
    body = body_of(TransferRequestMailer.transfer_completed(transfer_request('W')))

    assert_includes body, '<strong>Spielerin:</strong>'
    assert_includes body, 'Alle bestehenden Lizenzen der Spielerin wurden'
    assert_not_includes body, 'des Spielers'
  end

  test 'der vollzogene Transfer bleibt fuer einen Spieler unveraendert' do
    body = body_of(TransferRequestMailer.transfer_completed(transfer_request('M')))

    assert_includes body, '<strong>Spieler:</strong>'
    assert_includes body, 'Alle bestehenden Lizenzen des Spielers wurden'
  end

  test 'die erteilte Freigabe stellt den Satzanfang um' do
    tr = transfer_request('W', request_type: 'release')
    body = body_of(TransferRequestMailer.transfer_completed(tr))

    assert_includes body, 'Die Spielerin bleibt im Heimverein.'
  end

  test 'das Relativpronomen wird mitgegendert' do
    tr = transfer_request('W')
    body = body_of(TransferRequestMailer.secondary_club_notification(tr, @requesting_club))

    assert_includes body, 'die folgende Spielerin, die bei Ihrem Verein'
    assert_includes body, 'Alle Lizenzen der Spielerin wurden'
  end

  test 'die Zustimmungsanfrage spricht die Spielerin in ihrer Rolle an' do
    body = body_of(TransferRequestMailer.player_confirmation_request(transfer_request('W')))

    assert_includes body, 'als Spielerin transferieren'
  end

  test 'der Betreff der Ablehnung durch die Person traegt die gegenderte Bezeichnung' do
    mail = TransferRequestMailer.player_rejected_clubs_notification(transfer_request('W'))

    assert_includes mail.subject, 'abgelehnt durch Spielerin'
    assert_includes body_of(mail), 'wurde von der Spielerin abgelehnt'
  end

  # Divers und „nichts hinterlegt" bekommen dieselbe neutrale Form. Das ist
  # zugleich Datenschutz: Am Text des Vereinspostfachs laesst sich nicht
  # ablesen, dass bei genau diesem Profil „divers" steht.
  test 'divers und ohne Angabe lesen sich gleich und neutral' do
    %w[D].push(nil).each do |gender|
      body = body_of(TransferRequestMailer.transfer_completed(transfer_request(gender)))

      assert_includes body, '<strong>Spieler*in:</strong>', "gender=#{gender.inspect}"
      assert_includes body, 'Alle bestehenden Lizenzen der spielenden Person wurden', "gender=#{gender.inspect}"
    end
  end

  test 'der geplante Transfer und der deaktivierte Verein gendern ebenfalls' do
    scheduled = transfer_request('W', effective_date: 1.month.from_now.to_date)
    assert_includes body_of(TransferRequestMailer.transfer_scheduled(scheduled)),
                    'Bis zum Vollzug bleibt die Spielerin im abgebenden Verein'

    deactivated = transfer_request('W')
    assert_includes body_of(TransferRequestMailer.club_deactivated_notification(deactivated)),
                    'Die Spielerin bleibt im abgebenden Verein.'
  end

  test 'die Antragsmails nennen die folgende Spielerin im richtigen Fall' do
    tr = transfer_request('W')

    assert_includes body_of(TransferRequestMailer.new_request_to_former_club(tr)),
                    'für die folgende Spielerin gestellt'
    assert_includes body_of(TransferRequestMailer.rejected_notification(tr)),
                    'für die folgende Spielerin wurde abgelehnt'
  end

  # Fachbegriffe bleiben: „Spielerfreigabe" ist der Name des Vorgangs und nicht
  # die Bezeichnung der Person.
  test 'der Vorgangsname Spielerfreigabe wird nicht gegendert' do
    tr = transfer_request('W', request_type: 'release')

    assert_includes body_of(TransferRequestMailer.new_request_to_former_club(tr)), 'Spielerfreigabe'
    assert_not_includes body_of(TransferRequestMailer.new_request_to_former_club(tr)), 'Spielerinfreigabe'
  end
end
