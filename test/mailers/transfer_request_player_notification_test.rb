require 'test_helper'

# Die Mail "Neue Transferanfrage" ging an den abgebenden Verein *und* an den
# Spieler. Ihr Text fordert aber zum Anmelden in der Verwaltung auf und verlinkt
# /verwaltung/transfer-anfragen -- Spieler haben dort weder Zugang noch
# Logindaten. Der Spieler wird erst mit #player_confirmation_request
# angeschrieben, die per Token ohne Login zustimmen oder ablehnen laesst.
class TransferRequestPlayerNotificationTest < ActionMailer::TestCase
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

    @player = create(:player, first_name: 'Carl', last_name: 'Beispiel',
                              email: 'carl@example.de',
                              clubs: [{ 'club_id' => @former_club.id, 'home_club' => true,
                                        'valid_until' => nil }])
  end

  def transfer_request(attrs = {})
    TransferRequest.create!({
      player: @player,
      requesting_club: @requesting_club,
      former_club: @former_club,
      created_by: @user.id,
      season_id: 18,
      request_type: 'transfer'
    }.merge(attrs))
  end

  test 'die erste Mail geht nur an den abgebenden Verein, nicht an den Spieler' do
    mail = TransferRequestMailer.new_request_to_former_club(transfer_request)

    assert_equal ['alter@example.de'], mail.to
    assert_not_includes mail.to, @player.email
  end

  test 'auch bei einer Spielerfreigabe bekommt der Spieler die erste Mail nicht' do
    mail = TransferRequestMailer.new_request_to_former_club(transfer_request(request_type: 'release'))

    assert_equal ['alter@example.de'], mail.to
  end

  # Bisher hing an dieser Mail die Spieleradresse als stiller Ersatzempfaenger:
  # Ohne Verteiler beim abgebenden Verein ging sie trotzdem raus, nur eben an den
  # Falschen. Jetzt geht sie gar nicht raus, und das soll auch so bleiben, statt
  # als NullMail zu verpuffen, die eine reine `mail.to`-Pruefung nicht von einem
  # echten Versand unterscheidet.
  test 'ohne Verteiler beim abgebenden Verein wird gar nichts verschickt' do
    @former_club.update!(contact_email: nil)
    tr = transfer_request

    assert_emails 0 do
      TransferRequestMailer.new_request_to_former_club(tr).deliver_now
    end
  end

  # notification_emails speist sich aus contact_email *und* den Vereinsmanagern.
  # Ohne diesen Fall wuerde eine Aenderung am Verteiler nur im contact_email-Zweig
  # auffallen.
  test 'der Verteiler umfasst auch die Vereinsmanager des abgebenden Vereins' do
    @former_club.update!(contact_email: nil)
    create(:user, :vm, club_id: @former_club.id, email: 'vm-alter@example.de')

    mail = TransferRequestMailer.new_request_to_former_club(transfer_request)

    assert_equal ['vm-alter@example.de'], mail.to
  end

  test 'der Spieler bekommt die Zustimmungsanfrage mit Token-Links' do
    tr = transfer_request
    mail = TransferRequestMailer.player_confirmation_request(tr)

    assert_equal ['carl@example.de'], mail.to
    assert_includes mail.body.encoded, tr.player_confirmation_token
  end
end
