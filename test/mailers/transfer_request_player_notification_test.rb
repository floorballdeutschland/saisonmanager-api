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

  # --- Getrennte Empfaengerkreise ---------------------------------------------
  #
  # Bis hierher standen Vereinspostfaecher und die private Adresse der Person in
  # einem gemeinsamen `to:`. Damit lag die Adresse beim aufnehmenden Verein,
  # bevor ueberhaupt entschieden war.

  # Beide Aufrufformen je Aktion in einem Durchlauf: Eine neue Vorgangsmail, die
  # den Empfaengerkreis nicht trennt, faellt sonst erst auf, wenn sie in
  # Produktion die Adresse ausliefert.
  SPLIT_ACTIONS = [
    [:clubs_informed_lv_pending, 1],
    [:transfer_completed, 1],
    [:club_deactivated_notification, 1],
    [:release_revoked, 1],
    [:release_annulled_by_transfer, 2],
    [:transfer_scheduled, 1]
  ].freeze

  # Die Handliste oben beweist nichts ueber das, was NICHT drinsteht. Diese
  # beiden Tests schliessen die Luecke von zwei Seiten -- und sie ist real:
  # Waehrend dieser PR offen war, kam mit api#648 `transfer_scheduled` dazu, mit
  # genau dem gemeinsamen Verteiler, den die Trennung beseitigt.
  def audience_actions
    TransferRequestMailer.action_methods.select do |name|
      TransferRequestMailer.instance_method(name).parameters.include?(%i[key audience])
    end.map(&:to_s).sort
  end

  test 'die Liste deckt genau die Aktionen mit getrenntem Empfaengerkreis ab' do
    assert_equal audience_actions, SPLIT_ACTIONS.map { |aktion, _| aktion.to_s }.sort,
                 'eine Aktion mit `audience:` fehlt in SPLIT_ACTIONS (oder umgekehrt)'
  end

  # Der Mailer allein hilft nicht: `deliver_to_all_audiences` ist eine
  # Konvention, die nichts erzwingt, und ein Aufrufer, der nur die Haelfte
  # verschickt, faellt durch nichts auf -- die Vereine bekommen ihre Nachricht,
  # im Postfach sieht alles vollstaendig aus.
  test 'jede Aufrufstelle verschickt an beide Empfaengerkreise' do
    quellen = Dir.glob(Rails.root.join('app/**/*.rb')).reject { |datei| datei.end_with?('transfer_request_mailer.rb') }

    direkte_aufrufe = quellen.flat_map do |datei|
      inhalt = File.read(datei)
      audience_actions.filter_map do |aktion|
        "#{datei.sub("#{Rails.root}/", '')}: #{aktion}" if inhalt.include?("TransferRequestMailer.#{aktion}(")
      end
    end

    assert_empty direkte_aufrufe,
                 'diese Stellen rufen eine getrennte Aktion direkt auf statt ueber deliver_to_all_audiences'
  end

  test 'keine Vorgangsmail traegt die private Adresse im Verteiler der Vereine' do
    tr = transfer_request

    SPLIT_ACTIONS.each do |action, arity|
      args = Array.new(arity) { tr }
      to_clubs = TransferRequestMailer.public_send(action, *args)
      to_person = TransferRequestMailer.public_send(action, *args, audience: 'player')

      assert_not_includes Array(to_clubs.to), @player.email,
                          "#{action}: Spieleradresse steht im Verteiler der Vereine"
      # Welche Vereinspostfaecher es sind, entscheidet die einzelne Nachricht
      # (release_annulled_by_transfer geht bewusst nur an den Zielverein) --
      # geprueft wird hier, dass ueberhaupt eines uebrig bleibt.
      assert_not_empty Array(to_clubs.to), "#{action}: der Verteiler der Vereine ist leer"
      assert_equal [@player.email], Array(to_person.to),
                   "#{action}: die Nachricht an die Person geht nicht ausschliesslich an sie"
    end
  end

  test 'die Vollzugsmail erreicht beide Kreise, aber in getrennten Sendungen' do
    tr = transfer_request

    assert_emails 2 do
      perform_enqueued_jobs do
        TransferRequestMailer.deliver_to_all_audiences(:transfer_completed, tr)
      end
    end
  end

  # Ein Tippfehler im Empfaengerkreis darf nicht in den Vereins-Zweig fallen --
  # das waere genau die Zustellung, die diese Trennung beseitigt.
  test 'ein unbekannter Empfaengerkreis bricht ab' do
    tr = transfer_request

    assert_raises(ArgumentError) do
      TransferRequestMailer.transfer_completed(tr, audience: 'landesverband').deliver_now
    end
  end

  test 'ohne hinterlegte Adresse der Person geht nur die Sendung an die Vereine raus' do
    @player.update!(email: nil)
    tr = transfer_request

    # Eingereiht werden weiterhin beide Sendungen; die leere faellt erst im Job
    # als NullMail aus (deliver_later wertet die Aktion nicht vorab aus).
    # Gezaehlt wird deshalb die tatsaechliche Zustellung.
    assert_emails 1 do
      perform_enqueued_jobs do
        TransferRequestMailer.deliver_to_all_audiences(:transfer_completed, tr)
      end
    end
  end

  # --- Datenschutzinformation -------------------------------------------------

  test 'die Zustimmungsanfrage traegt die Datenschutzinformation' do
    body = TransferRequestMailer.player_confirmation_request(transfer_request).body.decoded

    assert_includes body, 'Art. 13 und 14 DSGVO'
    assert_includes body, PrivacyPolicy.url
    assert_includes body, PrivacyPolicy.responsible_body
  end

  # Zweck, Rechtsgrundlage, Empfaenger, Speicherdauer und die Rechte nach
  # Art. 15-21 stehen im Kapitel "Saisonmanager" der Datenschutzerklaerung. Ein
  # zweiter Wortlaut in der Mail laeuft dagegen auseinander -- der erste Entwurf
  # nannte eine andere Rechtsgrundlage und eine andere Speicherdauer als das
  # veroeffentlichte Kapitel. Der Test haelt die Aufgabenteilung fest: Die Mail
  # verweist, sie wiederholt nicht.
  # Nur der Abschnitt, nicht die ganze Mail: "Spielordnung" ist in
  # Transferkorrespondenz ein plausibles Wort, und ein in der Verwaltung
  # gepflegter Vorlagentext darf es benutzen, ohne diesen Test zu kippen.
  def privacy_notice_section(mail)
    body = mail.body.decoded
    index = body.index('Information zur Datenverarbeitung')

    assert_not_nil index, 'die Datenschutzinformation fehlt'
    body[index..]
  end

  test 'die Datenschutzinformation wiederholt die Datenschutzerklaerung nicht' do
    abschnitt = privacy_notice_section(TransferRequestMailer.player_confirmation_request(transfer_request))

    # Die Ueberschriften des Kapitels darf der Abschnitt nennen -- er verweist
    # darauf. Geprueft ist deshalb der Inhalt: die Rechtsgrundlage, ihre
    # Herleitung und die Aussage zum Drittlandtransfer.
    assert_not_includes abschnitt, 'Art. 6 Abs. 1'
    assert_not_includes abschnitt, 'Spielordnung'
    assert_not_includes abschnitt, 'Drittland'
  end

  # Das Kapitel steht am Ende einer langen Erklaerung, die mit Website, Cookies
  # und Newsletter beginnt: Ohne den Anker landet die Person oben und sucht.
  test 'der Verweis zeigt auf das Kapitel und nicht auf den Seitenanfang' do
    body = TransferRequestMailer.player_confirmation_request(transfer_request).body.decoded

    # Am Link festgemacht und nicht am blanken Fragment: Sonst genuegte das Wort
    # irgendwo im Text. Und ueber PrivacyPolicy.url, damit ein gesetztes
    # PRIVACY_POLICY_URL den Test nicht kippt -- die Variable ist der Zweck des
    # Service.
    assert_includes body, %(href="#{PrivacyPolicy.url}")
    assert_not_nil URI.parse(PrivacyPolicy.url).fragment,
                   'die Fundstelle zeigt auf den Seitenanfang statt auf das Kapitel'
  end

  test 'die Datenschutzinformation benennt den zustaendigen Landesverband' do
    body = TransferRequestMailer.transfer_completed(transfer_request, audience: 'player').body.decoded

    assert_includes body, @state_association.name
  end

  # Entscheiden darf der Verbund, nicht das Kind -- und der Kommentar an
  # #enable_privacy_notice! begruendet genau das. Ohne diesen Test bleibt die
  # Unterscheidung ungeprueft: In den uebrigen Tests hat der Verband keinen
  # Elternteil, `responsible_state_association` und `state_association` liefern
  # dort also denselben Datensatz.
  test 'die Datenschutzinformation nennt den Verbund und nicht den Kind-Verband' do
    verbund = create(:state_association, name: 'Spielverbund Nord')
    kind = create(:state_association, name: 'Floorball Bund Beispielstadt', parent: verbund)
    @former_club.update!(state_association_id: kind.id)

    abschnitt = privacy_notice_section(
      TransferRequestMailer.transfer_completed(transfer_request, audience: 'player')
    )

    assert_includes abschnitt, verbund.name
    assert_not_includes abschnitt, kind.name
  end

  # Ohne SBK-Adresse am Verbund faellt die Zeile weg; mit einer steht sie als
  # mailto da. Die Factory setzt keine, der zweite Fall war deshalb bisher der
  # einzige gepruefte -- unbeabsichtigt.
  test 'die Datenschutzinformation nennt die Kontaktadresse des Verbands' do
    @state_association.update!(sbk_email: 'sbk@lv.example')

    abschnitt = privacy_notice_section(
      TransferRequestMailer.transfer_completed(transfer_request, audience: 'player')
    )

    assert_includes abschnitt, 'mailto:sbk@lv.example'
  end

  # Ein Verein ohne Landesverband ist Altbestand, und `find_by` liefert dann
  # nil. Die Mail muss trotzdem zugestellt werden -- ohne den Satz zum
  # entscheidenden Verband, aber mit Verantwortlichem und Fundstelle.
  test 'ohne zustaendigen Verband bleibt die Information zustellbar' do
    @former_club.update!(state_association_id: nil)

    abschnitt = privacy_notice_section(
      TransferRequestMailer.transfer_completed(transfer_request, audience: 'player')
    )

    assert_includes abschnitt, PrivacyPolicy.responsible_body
    assert_includes abschnitt, PrivacyPolicy.url
    assert_not_includes abschnitt, 'Über den Vorgang selbst entscheidet'
  end

  test 'die Sendung an die Vereine traegt die Datenschutzinformation nicht' do
    body = TransferRequestMailer.transfer_completed(transfer_request).body.decoded

    assert_not_includes body, 'Art. 13 und 14 DSGVO'
  end

  # Der Grund, warum die Information im Layout steht und nicht im View: Ein
  # gepflegter Vorlagentext ERSETZT das View. Stuende sie dort, waere die
  # Pflichtangabe mit der ersten Textaenderung in der Admin-Oberflaeche still
  # verschwunden.
  test 'ein gepflegter Vorlagentext entfernt die Datenschutzinformation nicht' do
    EmailTemplate.create!(mailer_class: 'TransferRequestMailer', action_name: 'transfer_completed',
                          locale: 'de', body: '<p>Eigener Text der Verwaltung</p>')

    body = TransferRequestMailer.transfer_completed(transfer_request, audience: 'player').body.decoded

    assert_includes body, 'Eigener Text der Verwaltung'
    assert_includes body, 'Art. 13 und 14 DSGVO'
  end

  # --- Alarm zum unzustellbaren Widerruf --------------------------------------

  def revocation_messages(&)
    captured = []
    Sentry.stub(:capture_message, ->(message) { captured << message }, &)
    captured
  end

  # Seit die Nachricht getrennt rausgeht, ist eine leere Haelfte der Normalfall.
  # Der Alarm meinte aber nie das, sondern: Der Widerruf erreicht niemanden.
  test 'eine Person ohne Adresse loest keinen Widerrufs-Alarm aus' do
    @player.update!(email: nil)
    tr = transfer_request(request_type: 'release')

    captured = revocation_messages do
      TransferRequestMailer.release_revoked(tr).deliver_now
      TransferRequestMailer.release_revoked(tr, audience: 'player').deliver_now
    end

    assert_empty captured
  end

  # Die Gegenrichtung, und die eigentliche Daseinsberechtigung der
  # Gesamtverteiler-Pruefung: Ein aufgeloester Verein ohne Postfach darf keinen
  # Alarm ausloesen, solange die Person den Widerruf erfaehrt. Ohne diese
  # Pruefung meldete jeder solche Fall einen Fehlalarm.
  test 'Vereine ohne Postfach loesen keinen Widerrufs-Alarm aus' do
    @requesting_club.update!(contact_email: nil)
    @former_club.update!(contact_email: nil)
    @state_association.update!(sbk_email: nil)
    tr = transfer_request(request_type: 'release')

    captured = revocation_messages do
      TransferRequestMailer.release_revoked(tr).deliver_now
      TransferRequestMailer.release_revoked(tr, audience: 'player').deliver_now
    end

    assert_empty captured, 'der Widerruf hat die Person erreicht'
  end

  test 'erreicht der Widerruf niemanden, wird genau einmal gemeldet' do
    @player.update!(email: nil)
    @requesting_club.update!(contact_email: nil)
    @former_club.update!(contact_email: nil)
    @state_association.update!(sbk_email: nil)
    tr = transfer_request(request_type: 'release')

    captured = revocation_messages do
      TransferRequestMailer.release_revoked(tr).deliver_now
      TransferRequestMailer.release_revoked(tr, audience: 'player').deliver_now
    end

    assert_equal 1, captured.size
    assert_includes captured.first, "TransferRequest##{tr.id}"
  end
end
