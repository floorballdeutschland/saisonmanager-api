require 'test_helper'

# Empfänger der Vereinspost: Kontaktadresse plus die Vereinsmanager des
# Vereins. Alle bekommen sie standardmäßig; gespeichert wird nur, wer abgewählt
# ist. Der Verteiler entsteht bei jedem Versand aus den aktuellen Rechten, damit
# niemand Post bekommt, der die Rolle längst verloren hat.
class ClubNotificationEmailsTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @club = create(:club, contact_email: 'info@verein.example')
  end

  def vm(club, email:, **attrs)
    create(:user, :vm, club_id: club.id, email: email, **attrs)
  end

  test 'ohne Zutun bekommen alle Vereinsmanager die Vereinspost' do
    vm(@club, email: 'a@verein.example')
    vm(@club, email: 'b@verein.example')

    assert_equal %w[info@verein.example a@verein.example b@verein.example].sort,
                 @club.notification_emails.sort
  end

  test 'abgewaehlte Vereinsmanager fallen raus' do
    a = vm(@club, email: 'a@verein.example')
    b = vm(@club, email: 'b@verein.example')
    @club.update!(notify_user_ids: [a.id])

    assert_equal %w[info@verein.example a@verein.example].sort, @club.notification_emails.sort
    assert_equal [b.id], @club.reload.notify_excluded_user_ids
  end

  test 'wer alle abwaehlt, behaelt nur die Kontaktadresse' do
    vm(@club, email: 'a@verein.example')
    vm(@club, email: 'b@verein.example')
    @club.update!(notify_user_ids: [])

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  # Der Grund für die Abwahlliste: Eine gespeicherte Auswahl hätte den später
  # Berufenen ausgeschlossen, bis ihn jemand von Hand angehakt hätte.
  test 'ein spaeter berufener Vereinsmanager ist von selbst dabei' do
    a = vm(@club, email: 'a@verein.example')
    @club.update!(notify_user_ids: [a.id])

    vm(@club, email: 'neu@verein.example')

    assert_includes @club.reload.notification_emails, 'neu@verein.example'
  end

  test 'ohne Kontaktadresse bleiben die Vereinsmanager' do
    a = vm(@club, email: 'a@verein.example')
    vm(@club, email: 'abgewaehlt@verein.example')
    @club.update!(contact_email: nil, notify_user_ids: [a.id])

    assert_equal ['a@verein.example'], @club.notification_emails
  end

  # Die Abwahl nimmt nur auf, wen es gibt. Sonst hinge dort Müll, der einen
  # später berufenen Vereinsmanager mit derselben ID stumm aussperrt.
  test 'fremde IDs landen nicht in der Abwahl' do
    a = vm(@club, email: 'a@verein.example')
    fremder_vm = vm(create(:club), email: 'fremd@verein.example')
    @club.update!(notify_user_ids: [a.id, fremder_vm.id, 999_999])

    assert_equal [], @club.reload.notify_excluded_user_ids
  end

  # Der Kern der Auflösung: Die gespeicherte ID allein sagt nichts darüber, ob
  # die Person den Verein noch verwaltet.
  test 'wer die Vereinsrolle verliert, faellt aus dem Verteiler' do
    a = vm(@club, email: 'a@verein.example')
    assert_includes @club.notification_emails, 'a@verein.example'

    a.update!(permissions: [])

    assert_equal ['info@verein.example'], @club.reload.notification_emails
  end

  test 'ein Vereinsmanager eines anderen Vereins kommt nicht durch' do
    vm(create(:club), email: 'fremd@verein.example')

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  test 'archivierte Benutzer und leere Adressen fallen raus' do
    vm(@club, email: '')
    vm(@club, email: 'archiv@verein.example', archived_at: Time.current)

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  test 'doppelte Adressen erscheinen nur einmal' do
    vm(@club, email: 'info@verein.example')

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  # Auf Produktion trug ein Verein zwei Adressen mit Semikolon im Feld. Beide
  # bekamen nie etwas, weil das Feld als eine Adresse verschickt wird.
  test 'contact_email nimmt keine zwei Adressen mehr an' do
    club = build(:club, contact_email: 'a@example.org; b@example.org')

    assert_not club.valid?
    assert_includes club.errors.attribute_names, :contact_email
  end

  test 'contact_email darf leer bleiben' do
    assert_predicate build(:club, contact_email: nil), :valid?
    assert_predicate build(:club, contact_email: ''), :valid?
  end

  # Auf Produktion traegt ein Verein bereits zwei Adressen im Feld. Eine
  # unbedingte Pruefung haette jedes Speichern dieses Vereins blockiert, auch
  # das Deaktivieren, das in einer Maske ohne Adressfeld an einer Meldung ueber
  # die Adresse gescheitert waere.
  test 'eine ungueltige Bestandsadresse blockiert andere Aenderungen nicht' do
    club = create(:club)
    club.update_column(:contact_email, 'a@example.org; b@example.org')
    club.reload

    assert club.update(name: 'Neuer Name'), club.errors.full_messages.join(', ')
    assert_nothing_raised { club.deactivate!(create(:user, :admin).id) }
    assert_nothing_raised { club.reactivate! }
    assert_equal 'a@example.org; b@example.org', club.reload.contact_email
  end

  test 'wer die Bestandsadresse anfasst, muss die Regel einhalten' do
    club = create(:club)
    club.update_column(:contact_email, 'a@example.org; b@example.org')
    club.reload

    assert_not club.update(contact_email: 'c@example.org; d@example.org')
    assert_includes club.errors.attribute_names, :contact_email
    assert club.update(contact_email: 'c@example.org')
  end

  # Gegenprobe an einer echten Mail: Die Empfaengerliste muss auch dort
  # ankommen, nicht nur in notification_emails.
  test 'eine Vereinsmail geht an Kontaktadresse und Vereinsmanager' do
    a = vm(@club, email: 'a@verein.example')
    vm(@club, email: 'abgewaehlt@verein.example')
    @club.update!(notify_user_ids: [a.id])
    game_day = create(:game_day, club: @club)

    mail = ClubMailer.game_day_scan_reminder(@club, game_day)

    assert_equal %w[info@verein.example a@verein.example].sort, mail.to.sort
  end

  # jsonb-Containment ist typstreng. Ein Alt-Eintrag mit "4" statt 4 fiel aus
  # der Vorauswahl und der Vereinsmanager fehlte stumm in der Auswahlliste.
  test 'club_managers findet auch Alt-Einträge mit String-Werten' do
    user = create(:user, email: 'alt@verein.example',
                         permissions: [{ 'user_group_id' => '4', 'game_operation_id' => '0',
                                         'club_id' => @club.id.to_s }])

    assert_equal [user.id], @club.club_managers.map(&:id)
    assert_includes @club.notification_emails, 'alt@verein.example'
  end

  test 'club_managers listet die Vereinsmanager des Vereins' do
    a = vm(@club, email: 'a@verein.example')
    vm(create(:club), email: 'fremd@verein.example')

    assert_equal [a.id], @club.club_managers.map(&:id)
  end
end
