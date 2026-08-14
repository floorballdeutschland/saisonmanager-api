require 'test_helper'

# Empfänger der Vereinspost: Kontaktadresse plus die ausgewählten
# Vereinsmanager. Die Auswahl wird bei jedem Versand gegen die aktuellen Rechte
# aufgelöst, damit niemand Post bekommt, der die Rolle längst verloren hat.
class ClubNotificationEmailsTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @club = create(:club, contact_email: 'info@verein.example')
  end

  def vm(club, email:, **attrs)
    create(:user, :vm, club_id: club.id, email: email, **attrs)
  end

  test 'ohne Auswahl bleibt es bei der Kontaktadresse' do
    vm(@club, email: 'vm@verein.example')

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  test 'ausgewaehlte Vereinsmanager kommen dazu' do
    a = vm(@club, email: 'a@verein.example')
    b = vm(@club, email: 'b@verein.example')
    @club.update!(notify_user_ids: [a.id, b.id])

    assert_equal %w[info@verein.example a@verein.example b@verein.example].sort,
                 @club.notification_emails.sort
  end

  test 'nur die ausgewaehlten, nicht alle Vereinsmanager' do
    a = vm(@club, email: 'a@verein.example')
    vm(@club, email: 'ungewaehlt@verein.example')
    @club.update!(notify_user_ids: [a.id])

    assert_equal %w[info@verein.example a@verein.example].sort, @club.notification_emails.sort
  end

  test 'ohne Kontaktadresse bleiben die ausgewaehlten Vereinsmanager' do
    a = vm(@club, email: 'a@verein.example')
    @club.update!(contact_email: nil, notify_user_ids: [a.id])

    assert_equal ['a@verein.example'], @club.notification_emails
  end

  # Der Kern der Auflösung: Die gespeicherte ID allein sagt nichts darüber, ob
  # die Person den Verein noch verwaltet.
  test 'wer die Vereinsrolle verliert, faellt aus dem Verteiler' do
    a = vm(@club, email: 'a@verein.example')
    @club.update!(notify_user_ids: [a.id])
    assert_includes @club.notification_emails, 'a@verein.example'

    a.update!(permissions: [])

    assert_equal ['info@verein.example'], @club.reload.notification_emails
  end

  test 'ein Vereinsmanager eines anderen Vereins kommt nicht durch' do
    fremd = create(:club)
    fremder_vm = vm(fremd, email: 'fremd@verein.example')
    @club.update!(notify_user_ids: [fremder_vm.id])

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  test 'archivierte Benutzer und leere Adressen fallen raus' do
    ohne_mail = vm(@club, email: '')
    archiviert = vm(@club, email: 'archiv@verein.example', archived_at: Time.current)
    @club.update!(notify_user_ids: [ohne_mail.id, archiviert.id])

    assert_equal ['info@verein.example'], @club.notification_emails
  end

  test 'doppelte Adressen erscheinen nur einmal' do
    a = vm(@club, email: 'info@verein.example')
    @club.update!(notify_user_ids: [a.id])

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

  # Gegenprobe an einer echten Mail: Die Empfaengerliste muss auch dort
  # ankommen, nicht nur in notification_emails.
  test 'eine Vereinsmail geht an Kontaktadresse und ausgewaehlten Vereinsmanager' do
    a = vm(@club, email: 'a@verein.example')
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

    @club.update!(notify_user_ids: [user.id])
    assert_includes @club.notification_emails, 'alt@verein.example'
  end

  test 'club_managers listet die Vereinsmanager des Vereins' do
    a = vm(@club, email: 'a@verein.example')
    vm(create(:club), email: 'fremd@verein.example')

    assert_equal [a.id], @club.club_managers.map(&:id)
  end
end
