require 'test_helper'

# Postfächer eines untergeordneten Landesverbands fallen auf den übergeordneten
# Verbund zurück (analog effective_rsk_email). Die Verbandsmaske sperrt die
# Felder bei einem Kind-LV und weist sie als „geerbt" aus; ohne Rückfall im
# Modell lasen die Mailer die Adresse direkt am Kind-Datensatz, bei Transfers
# über den Verein, bei Spieltags-, Expresslizenz- und Berichtsmails über den
# Spielbetrieb der Liga.
class StateAssociationEffectiveEmailTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
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

  test 'Postfach erbt ueber mehrere Ebenen bis zur Wurzel' do
    enkel = create(:state_association, parent: @child)

    assert_equal 'sbk@verbund.example.com', enkel.effective_sbk_email
    assert_equal 'vsk@verbund.example.com', enkel.effective_vsk_email
  end

  test 'Ringverweis in der Hierarchie wird abgelehnt' do
    @verbund.parent_id = @child.id

    assert_not @verbund.valid?
    assert_includes @verbund.errors[:parent_id].join, 'Ringverweis'
  end

  test 'eigener Landesverband als Verbund wird abgelehnt' do
    @child.parent_id = @child.id

    assert_not @child.valid?
    assert_includes @child.errors[:parent_id].join, 'eigene'
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
    mail = TransferRequestMailer.pending_lv_notification(transfer_request_between(@child, @child))

    assert_equal ['sbk@verbund.example.com'], mail.to
  end

  # Der Text nannte den Landesverband des abgebenden Vereins. Fuer einen Verein
  # unter einem Verbund war das der Falsche: Gelesen und genehmigt hat der
  # Verbund, im Text stand der Kind-LV (auf Prod der Floorball Bund Hamburg,
  # obwohl der Landesverband Schleswig-Holstein entschieden hat).
  test 'Mailtext nennt den genehmigenden Verbund, nicht den Kind-LV' do
    verbund = create(:state_association, name: 'Verbund Nord', sbk_email: 'nord@example.com')
    kind = create(:state_association, name: 'Kind-LV Sued', parent: verbund)
    tr = transfer_request_between(kind, kind)

    body = TransferRequestMailer.pending_lv_notification(tr).body.decoded
    assert_includes body, 'Verbund Nord'
    assert_not_includes body, 'Kind-LV Sued'

    clubs_body = TransferRequestMailer.clubs_informed_lv_pending(tr).body.decoded
    assert_includes clubs_body, 'Verbund Nord'
    assert_not_includes clubs_body, 'Kind-LV Sued'
  end

  test 'ohne Verbund nennt der Mailtext den Landesverband des Vereins selbst' do
    solo = create(:state_association, name: 'Solo-LV', sbk_email: 'solo@example.com')
    tr = transfer_request_between(solo, solo)

    assert_includes TransferRequestMailer.pending_lv_notification(tr).body.decoded, 'Solo-LV'
  end

  test 'Abschlussmail nennt die SBK des Verbunds als Empfaenger' do
    mail = TransferRequestMailer.transfer_completed(transfer_request_between(@child, @child))

    assert_includes mail.to, 'sbk@verbund.example.com'
  end

  # Der aufnehmende Landesverband bekommt keine eigene Abschlussmail mehr --
  # auch dann nicht, wenn hinter ihm ein anderes Postfach steht als beim
  # abgebenden. Genau dieser Fall hat sie frueher ausgeloest.
  #
  # Der Vorgang ist entschieden, wenn sie ankommt: Sie forderte nichts und
  # verdeckte im SBK-Postfach die Nachrichten, die etwas fordern. Was der
  # aufnehmende Verband daraus wissen wollte, steht in seiner Uebersicht
  # „Eingehende Transfers & Freigaben".
  test 'aufnehmender LV bekommt keine eigene Abschlussmail' do
    fremder_lv = create(:state_association, sbk_email: 'sbk@fremd.example.com')
    tr = transfer_request_between(@child, fremder_lv)

    perform_enqueued_jobs do
      tr.send(:send_completion_emails, [])
    end

    # Die Zahl und nicht nur die eine Adresse: Ein Test auf
    # `assert_not_includes 'sbk@fremd...'` liesse eine wiedereingefuehrte Mail
    # an das VSK-Postfach, an die Vereinsadressen oder an ein geerbtes Kind-LV
    # anstandslos durch. `send_completion_emails([])` erzeugt genau eine.
    assert_equal 1, ActionMailer::Base.deliveries.size,
                 'genau eine Abschlussmail, keine zweite an den aufnehmenden LV'

    empfaenger = ActionMailer::Base.deliveries.flat_map(&:to)
    assert_includes empfaenger, 'sbk@verbund.example.com',
                    'die abgebende Seite wird weiterhin benachrichtigt'
    assert_not_includes empfaenger, 'sbk@fremd.example.com'
  end

  # Die Zusatzmail hing an ZWEI Absendestellen. Der Freigabeweg ist der, um den
  # es fachlich geht (Zweitspielrecht) -- ohne diesen Test liesse er sich
  # wieder einbauen, ohne dass etwas faellt.
  test 'auch der Freigabeweg verschickt keine zweite Mail an den aufnehmenden LV' do
    fremder_lv = create(:state_association, sbk_email: 'sbk@fremd.example.com')
    tr = transfer_request_between(@child, fremder_lv)
    tr.update!(request_type: 'release', status: 'pending_lv')

    perform_enqueued_jobs do
      tr.execute_release!(create(:user).id)
    end

    # Eine Sendung, weil die Testperson keine Adresse hat: Der Verteiler der
    # Person faellt als NullMail aus. Geprueft ist ohnehin die Aussage des
    # Tests -- der fremde Landesverband steht in keiner der Sendungen.
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_not_includes ActionMailer::Base.deliveries.flat_map(&:to), 'sbk@fremd.example.com'
  end

  # Der Widerruf einer bereits ERTEILTEN Freigabe erreichte die aufnehmende
  # Seite ueber keinen Kanal: `revoke_release!` verschickte nichts, und aus der
  # Uebersicht "Eingehende Transfers & Freigaben" faellt ein widerrufener
  # Vorgang heraus -- die Zeile verschwand einfach. Der Verein setzt den Spieler
  # zu dem Zeitpunkt womoeglich gerade ein.
  test 'Widerruf einer Freigabe erreicht den aufnehmenden Landesverband' do
    fremder_lv = create(:state_association, sbk_email: 'sbk@fremd.example.com')
    tr = transfer_request_between(@child, fremder_lv)
    tr.update!(request_type: 'release', status: 'approved', lv_approved_at: Time.current)

    perform_enqueued_jobs do
      tr.revoke_release!(create(:user).id, 'Irrtum bei der Freigabe')
    end

    # Ueber den Empfaenger ausgewaehlt und nicht ueber die Position: Seit die
    # Nachricht getrennt an die Stellen und an die Person geht, ist
    # `deliveries.last` die Sendung an die Person -- und die ist heute nur
    # deshalb leer, weil die Testperson keine Adresse hat.
    mail = ActionMailer::Base.deliveries.find { |sendung| sendung.to.include?('sbk@fremd.example.com') }
    assert_not_nil mail
    assert_includes mail.subject, 'zurueckgezogen'
    assert_includes mail.body.decoded, 'Irrtum bei der Freigabe',
                    'die Begruendung ist der einzige einordnende Inhalt'

    # Der Empfaengerkreis ist die Aussage dieser Mail, nicht ein Detail: Eine
    # Reduktion auf einen einzigen Empfaenger oder ein versehentlich ergaenztes
    # Postfach der abgebenden Seite liefe sonst still durch.
    assert_includes mail.to, 'sbk@fremd.example.com', 'der aufnehmende Landesverband'
    assert_includes mail.to, 'neu@example.com', 'der freigegebene Verein'
    assert_includes mail.to, 'alt@example.com', 'der Heimverein'
    assert_not_includes mail.to, 'sbk@verbund.example.com',
                        'der abgebende LV hat den Widerruf ausgeloest'
  end

  test 'Spieltags-Veto erreicht die SBK des Verbunds' do
    game_day = create(:game_day)
    referee_mail = GameDayMailer.referee_checklist_veto(game_day, create(:referee), [], @child)
    team_mail = GameDayMailer.team_checklist_veto(game_day, create(:team), [], @child)

    assert_equal ['sbk@verbund.example.com'], referee_mail.to
    assert_equal ['sbk@verbund.example.com'], team_mail.to
  end

  test 'Expresslizenz-Antrag erreicht die SBK des Verbunds' do
    go = GameOperation.create!(name: "SBK #{SecureRandom.hex(4)}", short_name: 'SBX',
                               path: "sbk-#{SecureRandom.hex(4)}", state_association: @child)
    league = create(:league, game_operation: go)
    team = create(:team, league: league)

    mail = PlayerMailer.express_license_requested(create(:player), team, league)

    assert_equal ['sbk@verbund.example.com'], mail.to
  end

  private

  def transfer_request_between(former_lv, requesting_lv)
    TransferRequest.create!(
      player: create(:player),
      former_club: create(:club, state_association: former_lv, contact_email: 'alt@example.com'),
      requesting_club: create(:club, state_association: requesting_lv, contact_email: 'neu@example.com'),
      status: 'pending_lv',
      season_id: 18,
      created_by: 1
    )
  end
end
