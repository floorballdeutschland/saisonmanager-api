require 'test_helper'

# Beim Zusammenfuehren behaelt die Person die kleinste Schiedsrichternummer, die
# Stammdaten kommen vom Profil mit der spaeteren Lizenz (Dubletten-Durchgang
# 23.10.2026). Die aufgegebene Nummer fuehrt danach weiter zum Master.
class RefereeMergeNumberTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    create(:setting)
  end

  def old_profile(**attrs)
    create(:referee, lizenznummer: 921, vorname: 'Jens', nachname: 'Kuerbis', email: nil, club_id: create(:club).id,
                     lizenzstufe: 'LJ', gueltigkeit: Date.new(2010, 7, 31), **attrs)
  end

  def current_profile(**attrs)
    create(:referee, lizenznummer: 3454, vorname: 'Jens', nachname: 'Kürbis', email: 'jens@example.org',
                     club_id: create(:club).id, lizenzstufe: 'N2', gueltigkeit: Date.new(2028, 9, 30), **attrs)
  end

  def referee_user(referee, user_name: "sr-#{referee.lizenznummer}")
    create(:user, user_name: user_name, referee_id: referee.id, permissions: [{ 'user_group_id' => 6 }])
  end

  test 'merge_roles macht die kleinere Nummer zum Master, egal von welcher Seite' do
    small = old_profile
    large = current_profile

    assert_equal [small, large], Referee.merge_roles(small, large)
    assert_equal [small, large], Referee.merge_roles(large, small)
  end

  test 'merge_roles bevorzugt das Profil mit Nummer und laesst zwei ohne Nummer in der gewaehlten Richtung' do
    numbered = old_profile
    guest_a = create(:referee, lizenznummer: nil, guest: true)
    guest_b = create(:referee, lizenznummer: nil, guest: true)

    assert_equal [numbered, guest_a], Referee.merge_roles(guest_a, numbered)
    assert_equal [guest_b, guest_a], Referee.merge_roles(guest_b, guest_a)
  end

  test 'die Stammdaten kommen vom Profil mit der spaeteren Lizenz' do
    master = old_profile(email: 'alt@example.org')
    current = current_profile

    current.reload.merge_into!(master)

    master.reload
    assert_equal 921, master.lizenznummer
    assert_equal 'Kürbis', master.nachname
    assert_equal 'jens@example.org', master.email
    assert_equal current.club_id, master.club_id
    assert_equal ['N2', Date.new(2028, 9, 30)], [master.lizenzstufe, master.gueltigkeit]
  end

  test 'ein leerer Wert am aktuellen Profil loescht nichts am Master' do
    master = old_profile(telefonnummer: '0171 123')
    current = current_profile(telefonnummer: nil)

    current.reload.merge_into!(master)

    assert_equal '0171 123', master.reload.telefonnummer
  end

  test 'ist der Master das aktuelle Profil, fuellt die Dublette nur Luecken' do
    master = current_profile(lizenznummer: 500)
    older = old_profile(lizenznummer: 600, telefonnummer: '0171 123')

    club_id = master.club_id
    refute_equal club_id, older.club_id

    older.merge_into!(master)

    master.reload
    assert_equal 'Kürbis', master.nachname
    assert_equal club_id, master.club_id
    assert_equal '0171 123', master.telefonnummer
  end

  test 'das Konto wandert mit, heisst danach sr-<neue Nummer> und die Person bekommt eine Mail' do
    master = old_profile
    current = current_profile
    user = referee_user(current)

    assert_enqueued_email_with RefereeMailer, :number_change,
                               args: [master, { previous_number: 3454, user_name: 'sr-921', own_account: true }] do
      current.reload.merge_into!(master)
    end

    user.reload
    assert_equal master.id, user.referee_id
    assert_equal 'sr-921', user.user_name
  end

  test 'ohne Konto geht die Mail ohne Login raus' do
    master = old_profile
    current = current_profile

    assert_enqueued_email_with RefereeMailer, :number_change,
                               args: [master, { previous_number: 3454, user_name: nil, own_account: true }] do
      current.reload.merge_into!(master)
    end
  end

  test 'ein von Hand vergebener Login bleibt und steht so in der Mail' do
    master = old_profile
    current = current_profile
    user = referee_user(current, user_name: 'jens.kuerbis')

    assert_enqueued_email_with RefereeMailer, :number_change,
                               args: [master, { previous_number: 3454, user_name: 'jens.kuerbis', own_account: true }] do
      current.reload.merge_into!(master)
    end

    assert_equal 'jens.kuerbis', user.reload.user_name
  end

  test 'ist sr-<neue Nummer> schon vergeben, bleibt der alte Login' do
    master = old_profile
    current = current_profile
    create(:user, user_name: 'sr-921')
    user = referee_user(current)

    current.reload.merge_into!(master)

    assert_equal 'sr-3454', user.reload.user_name
    assert_equal master.id, user.referee_id
  end

  test 'hat der Master schon ein Konto, wird das der Dublette abgehaengt und bleibt nicht am toten Profil' do
    master = old_profile(email: 'konto@example.org')
    current = current_profile
    master_user = referee_user(master)
    secondary_user = referee_user(current)

    assert_enqueued_email_with RefereeMailer, :number_change,
                               args: [master, { previous_number: 3454, user_name: 'sr-921', own_account: false }] do
      current.reload.merge_into!(master)
    end

    assert_equal master.id, master_user.reload.referee_id
    assert_nil secondary_user.reload.referee_id
    assert_equal 'sr-3454', secondary_user.user_name
  end

  test 'hat der Master ein Konto, bleibt seine Adresse, weil sie dem Konto gehoert' do
    master = old_profile(email: 'konto@example.org')
    current = current_profile
    referee_user(master)

    current.reload.merge_into!(master)

    master.reload
    assert_equal 'konto@example.org', master.email
    assert_equal 'Kürbis', master.nachname
  end

  test 'merge_into! meldet Konto und Mailstatus zurueck und kann sofort senden' do
    master = old_profile
    current = current_profile
    referee_user(current)

    outcome = nil
    assert_emails 1 do
      outcome = current.reload.merge_into!(master, nil, deliver_now: true)
    end
    assert_no_enqueued_emails

    assert_equal 'Konto sr-3454 -> sr-921', outcome.account
    assert_equal RefereeNotification::SENT, outcome.mail
  end

  test 'aendert sich die Nummer der Person nicht, geht keine Mail raus' do
    master = current_profile(lizenznummer: 500)
    older = old_profile(lizenznummer: 600)
    user = referee_user(older)

    assert_no_enqueued_emails do
      older.reload.merge_into!(master)
    end
    # Ohne Mail kein neuer Login: Die Person erfuehre sonst nie, dass sr-600 weg ist.
    user.reload
    assert_equal master.id, user.referee_id
    assert_equal 'sr-600', user.user_name
  end

  test 'das Konto bleibt am Master, auch wenn der Aufrufer die Konto-Assoziation schon geladen hat' do
    master = old_profile
    current = current_profile
    user = referee_user(current)
    current.reload
    assert_equal user, current.user

    current.merge_into!(master)

    assert_equal master.id, user.reload.referee_id
  end

  test 'ein Gast-Konto wird nie umbenannt' do
    master = old_profile
    guest = current_profile(guest: true)
    user = referee_user(guest, user_name: 'sr-3454')

    guest.reload.merge_into!(master)

    assert_equal 'sr-3454', user.reload.user_name
  end

  test 'der Login wird ohne Ruecksicht auf Gross-/Kleinschreibung erkannt' do
    master = old_profile
    current = current_profile
    user = referee_user(current, user_name: 'SR-3454')

    current.reload.merge_into!(master)

    assert_equal 'sr-921', user.reload.user_name
  end

  test 'die oeffentliche Kursanmeldung erkennt die Person an der aufgegebenen Nummer' do
    master = old_profile(geburtsdatum: Date.new(1995, 7, 13))
    current_profile(geburtsdatum: Date.new(1995, 7, 13)).merge_into!(master)
    controller = PublicRefereeCoursesController.new

    assert_equal master, controller.send(:known_referee, '3454', '1995-07-13')
    assert_nil controller.send(:known_referee, '3454', '1995-07-14')
    master.update_columns(email: nil)
    assert_nil controller.send(:known_referee, '3454', '1995-07-13')
  end

  test 'die aufgegebene Nummer fuehrt zum Master, auch ueber eine Kette' do
    a = create(:referee, lizenznummer: 100)
    b = create(:referee, lizenznummer: 200)
    c = create(:referee, lizenznummer: 300)
    b.merge_into!(a)
    a.update_columns(merged_into_id: c.id)

    assert_equal c, Referee.canonical_for_lizenznummer(200)
    assert_equal c, Referee.canonical_for_lizenznummer(300)
    assert_nil Referee.canonical_for_lizenznummer(999)
  end

  test 'eine zirkulaere Kette liefert nil statt endlos zu laufen' do
    a = create(:referee, lizenznummer: 100)
    b = create(:referee, lizenznummer: 200)
    a.update_columns(merged_into_id: b.id)
    b.update_columns(merged_into_id: a.id)

    assert_nil Referee.canonical_for_lizenznummer(100)
  end

  test 'der Kursimport trifft ueber die aufgegebene Nummer den Master' do
    master = old_profile
    current_profile.merge_into!(master)
    service = RefereeCourseImportService.allocate

    ref, = service.send(:find_best_match, { lizenznummer: 3454, vorname: 'Jens', nachname: 'Kürbis' })

    assert_equal master, ref
    assert_equal 921, service.send(:effective_lizenznummer, 3454, ref)
    assert_equal 'lizenznummer', service.send(:merged_number_warning, 3454, ref).first['field']
    assert_empty service.send(:merged_number_warning, 921, ref)
  end

  test 'der E-Mail-Import schreibt eine Zeile mit aufgegebener Nummer an den Master' do
    master = old_profile
    current_profile(email: nil).merge_into!(master)

    report = RefereeEmailImport.new(csv_content: "Lizenznummer;E-Mailadresse\n3454;jens@example.org").call

    assert_equal 'jens@example.org', master.reload.email
    assert_empty report[:not_found]
  end

  test 'der E-Mail-Import behandelt alte und neue Nummer in einer Datei als dieselbe Person' do
    master = old_profile
    current_profile(email: nil).merge_into!(master)

    report = RefereeEmailImport.new(
      csv_content: "Lizenznummer;E-Mailadresse\n921;erste@example.org\n3454;zweite@example.org"
    ).call

    assert_equal 'erste@example.org', master.reload.email
    assert_equal 1, report[:updated].size
  end
end
