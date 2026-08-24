require 'test_helper'

class RefereeChangeRequestTest < ActiveSupport::TestCase
  setup do
    @state_association = create(:state_association)
    @club = create(:club, name: 'Eigener Verein', state_association: @state_association)
    @other_club = create(:club, name: 'Neuer Verein', state_association: @state_association)
    @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel',
                                geburtsdatum: Date.new(1990, 1, 1), club: @club)
  end

  test 'Namenskorrektur schreibt den neuen Wert ans Profil' do
    request = create_request(correction_type: 'nachname', new_value: 'Musterfrau')

    assert request.approve!(99, 'Heiratsurkunde lag vor')
    assert_equal 'Musterfrau', @referee.reload.nachname
    assert_equal 'approved', request.reload.status
    assert_equal 99, request.reviewed_by_user_id
    assert_not_nil request.decided_at
  end

  test 'Geburtsdatum wird als Datum uebernommen' do
    request = create_request(correction_type: 'geburtsdatum', new_value: '1991-02-03')

    assert request.approve!(99)
    assert_equal Date.new(1991, 2, 3), @referee.reload.geburtsdatum
  end

  test 'unlesbares Geburtsdatum wird abgewiesen statt das Datum zu loeschen' do
    request = build_request(correction_type: 'geburtsdatum', new_value: '32.13.1990')

    assert_not request.valid?
    assert_equal Date.new(1990, 1, 1), @referee.reload.geburtsdatum
  end

  # Date.parse liest Bruchstuecke: "03" wuerde zum 3. des laufenden Monats und
  # bei der Genehmigung das echte Geburtsdatum ueberschreiben.
  test 'Datums-Bruchstueck wird abgewiesen' do
    assert_not build_request(correction_type: 'geburtsdatum', new_value: '03').valid?
    assert_not build_request(correction_type: 'geburtsdatum', new_value: '1990-1-1').valid?
  end

  test 'Geburtsdatum in der Zukunft wird abgewiesen' do
    request = build_request(correction_type: 'geburtsdatum', new_value: 1.year.from_now.to_date.iso8601)

    assert_not request.valid?
  end

  test 'Vereinswechsel setzt den neuen Verein' do
    request = create_request(correction_type: 'verein', new_club: @other_club)

    assert request.approve!(99)
    assert_equal @other_club.id, @referee.reload.club_id
  end

  test 'Vereinsantrag ohne Verein ist ungueltig' do
    assert_not build_request(correction_type: 'verein').valid?
  end

  test 'stillgelegter Verein ist nicht beantragbar' do
    @other_club.update!(deactivated_at: Time.current)

    assert_not build_request(correction_type: 'verein', new_club: @other_club).valid?
  end

  test 'Antrag ohne Aenderung wird abgewiesen' do
    assert_not build_request(correction_type: 'vorname', new_value: 'Anna').valid?
    assert_not build_request(correction_type: 'verein', new_club: @club).valid?
  end

  test 'pro Feld nur ein offener Antrag' do
    create_request(correction_type: 'vorname', new_value: 'Anne')

    zweiter = build_request(correction_type: 'vorname', new_value: 'Annika')
    assert_not zweiter.valid?
    # Ein anderes Feld bleibt beantragbar.
    assert build_request(correction_type: 'nachname', new_value: 'Musterfrau').valid?
  end

  test 'entschiedener Antrag gibt den Weg fuer einen neuen frei' do
    request = create_request(correction_type: 'vorname', new_value: 'Anne')
    request.reject!(99, 'Nachweis fehlt')

    assert build_request(correction_type: 'vorname', new_value: 'Annika').valid?
  end

  test 'zweite Entscheidung laeuft ins Leere statt doppelt zu wirken' do
    request = create_request(correction_type: 'nachname', new_value: 'Musterfrau')

    assert request.approve!(99)
    assert_not request.approve!(98)
    assert_not request.reject!(98, 'zu spaet')
    assert_equal 'approved', request.reload.status
  end

  test 'zurueckgezogener Antrag ist nicht mehr entscheidbar' do
    request = create_request(correction_type: 'nachname', new_value: 'Musterfrau')

    assert request.withdraw!
    assert_not request.approve!(99)
    assert_equal 'Beispiel', @referee.reload.nachname
  end

  test 'Ablehnung laesst das Profil unveraendert' do
    request = create_request(correction_type: 'nachname', new_value: 'Musterfrau')

    assert request.reject!(99, 'Nachweis fehlt')
    assert_equal 'Beispiel', @referee.reload.nachname
    assert_equal 'Nachweis fehlt', request.reload.decision_note
  end

  # Der Antrag darf nicht am toten Zweitprofil haengenbleiben: Der Schiri saehe
  # ihn nicht mehr, die RSK koennte ihn aber weiter genehmigen.
  test 'offener Antrag wandert beim Zusammenfuehren zum Master' do
    zweitprofil = create(:referee, vorname: 'Anna', nachname: 'Beispiel', club: @club)
    antrag = RefereeChangeRequest.create!(referee: zweitprofil, correction_type: 'nachname',
                                          new_value: 'Musterfrau')

    zweitprofil.merge_into!(@referee, 1)

    assert_equal @referee.id, antrag.reload.referee_id
  end

  test 'doppelter offener Antrag zum selben Feld faellt beim Zusammenfuehren weg' do
    create_request(correction_type: 'nachname', new_value: 'Musterfrau')
    zweitprofil = create(:referee, vorname: 'Anna', nachname: 'Beispiel', club: @club)
    doppelt = RefereeChangeRequest.create!(referee: zweitprofil, correction_type: 'nachname',
                                           new_value: 'Andere')

    zweitprofil.merge_into!(@referee, 1)

    assert_not RefereeChangeRequest.exists?(doppelt.id)
    assert_equal 1, @referee.reload.referee_change_requests.pending.count
  end

  test 'aktueller Wert wird zum Anzeigezeitpunkt gelesen' do
    request = create_request(correction_type: 'nachname', new_value: 'Musterfrau')
    @referee.update!(nachname: 'Zwischenstand')

    assert_equal 'Zwischenstand', request.reload.current_value
  end

  private

  def build_request(attrs)
    RefereeChangeRequest.new({ referee: @referee }.merge(attrs))
  end

  def create_request(attrs)
    request = build_request(attrs)
    request.save!
    request
  end
end
