# frozen_string_literal: true

require 'test_helper'

class LegacyImport::MembershipCloserTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  test 'schließt offene Legacy-Heimatmitgliedschaft zum Start des Heimat-Folgevereins' do
    clubs = [
      { 'club_id' => 42, 'home_club' => true },
      { 'club_id' => 37, 'home_club' => true, 'created_at' => '2015-09-15T09:34:58+02:00',
        'valid_until' => '2023-01-13T15:53:54.010+01:00' },
      { 'club_id' => 126, 'home_club' => true, 'created_at' => '2023-01-13T15:53:54.011+01:00' }
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert changed
    assert_equal '2015-09-15T09:34:58+02:00', new_clubs[0]['valid_until']
    # datierte Einträge bleiben unverändert
    assert_equal '2023-01-13T15:53:54.010+01:00', new_clubs[1]['valid_until']
    assert_nil new_clubs[2]['valid_until']
  end

  test 'eine Freigabe schließt die Heimatmitgliedschaft NICHT (Vorfall 2026-07-13)' do
    # Leon-Konstellation: undatierte Heimatmitgliedschaft + datierte Freigabe
    # beim Zweitverein. Der Spieler ist nie gewechselt — Heimat bleibt offen.
    clubs = [
      { 'club_id' => 109, 'home_club' => true },
      { 'club_id' => 119, 'home_club' => false, 'created_at' => '2015-09-19T11:41:31+02:00',
        'valid_until' => '2016-07-15T00:00:00+02:00' }
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert_not changed
    assert_nil new_clubs[0]['valid_until']
  end

  test 'Legacy-Freigabe wird am frühesten datierten Folgeeintrag beliebiger Art geschlossen' do
    clubs = [
      { 'club_id' => 7, 'home_club' => false },
      { 'club_id' => 8, 'home_club' => false, 'created_at' => '2016-01-01T00:30:00+01:00' }
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert changed
    assert_equal '2016-01-01T00:30:00+01:00', new_clubs[0]['valid_until']
  end

  test 'wählt den frühesten Folgeeintrag über echte Zeit (nicht lexikografisch)' do
    clubs = [
      { 'club_id' => 1, 'home_club' => true },
      # späteres Datum, aber Offset ließe String-Vergleich kippen
      { 'club_id' => 2, 'home_club' => true, 'created_at' => '2016-01-01T00:30:00+01:00' },
      { 'club_id' => 3, 'home_club' => true, 'created_at' => '2015-09-15T09:34:58+02:00' }
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert changed
    assert_equal '2015-09-15T09:34:58+02:00', new_clubs[0]['valid_until']
  end

  test 'lässt offene Legacy-Mitgliedschaft ohne Folgeverein unverändert' do
    clubs = [{ 'club_id' => 42, 'home_club' => true }]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert_not changed
    assert_nil new_clubs[0]['valid_until']
  end

  test 'fasst datierte und bereits beendete Einträge nicht an' do
    clubs = [
      { 'club_id' => 5, 'created_at' => '2018-01-01T00:00:00+01:00', 'valid_until' => '2019-01-01T00:00:00+01:00' },
      { 'club_id' => 6, 'created_at' => '2019-01-01T00:00:00+01:00' }
    ]

    _new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert_not changed
  end

  test 'mutiert das Eingabe-Array nicht' do
    clubs = [
      { 'club_id' => 42, 'home_club' => true },
      { 'club_id' => 37, 'home_club' => true, 'created_at' => '2015-09-15T09:34:58+02:00' }
    ]

    LegacyImport::MembershipCloser.close(clubs)

    assert_nil clubs[0]['valid_until']
  end

  test 'ignoriert Platzhalter-/Ablage-Verein als Folgeverein und nimmt den nächsten echten' do
    clubs = [
      { 'club_id' => 42, 'home_club' => true },
      { 'club_id' => 83, 'home_club' => true, 'created_at' => '2015-01-01T00:00:00+01:00' }, # Ablage/Junk – ignorieren
      { 'club_id' => 37, 'home_club' => true, 'created_at' => '2016-09-15T09:34:58+02:00' }  # echter Folgeverein
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs, ignore_club_ids: [83])

    assert changed
    assert_equal '2016-09-15T09:34:58+02:00', new_clubs[0]['valid_until']
  end

  test 'lässt offen, wenn der einzige Folgeeintrag ein ignorierter Verein ist' do
    clubs = [
      { 'club_id' => 24, 'home_club' => true },
      { 'club_id' => 83, 'home_club' => true, 'created_at' => '2015-12-09T00:00:00+01:00' } # nur Junk
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs, ignore_club_ids: [83])

    assert_not changed
    assert_nil new_clubs[0]['valid_until']
  end

  test 'Rückkehr zum selben Verein zählt nicht als Folgeverein' do
    clubs = [
      { 'club_id' => 42, 'home_club' => true },
      { 'club_id' => 42, 'home_club' => true, 'created_at' => '2018-11-13T00:00:00+01:00' } # selber Verein
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert_not changed
    assert_nil new_clubs[0]['valid_until']
  end

  test 'selber Verein wird übersprungen, anderer echter Verein schließt trotzdem' do
    clubs = [
      { 'club_id' => 42, 'home_club' => true },
      { 'club_id' => 42, 'home_club' => true, 'created_at' => '2014-01-01T00:00:00+01:00' }, # selber Verein – ignorieren
      { 'club_id' => 37, 'home_club' => true, 'created_at' => '2016-09-15T09:34:58+02:00' }  # anderer Verein
    ]

    new_clubs, changed = LegacyImport::MembershipCloser.close(clubs)

    assert changed
    assert_equal '2016-09-15T09:34:58+02:00', new_clubs[0]['valid_until']
  end
end
