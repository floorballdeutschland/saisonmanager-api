require 'test_helper'

class RefereeCourseImportServiceTest < ActiveSupport::TestCase
  # Alt-Vorlage: Stufe, Datum und Punkte teilen sich denselben Namen, der Header
  # ist damit nicht eindeutig auflösbar → positionaler Fallback.
  HEADER = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
           "Kurs 1 Testversion;Kurs 1;Kurs 2;Kurs 2;Kurs 2 Testversion;Kurs 2;Ausbilder\n".freeze

  # LV-Vorlage 2026: eindeutige Überschriften (mehrzeilig in Quotes) und fünf
  # zusätzliche LV-Arbeitsspalten, „Kommentar LV" steht vor „Ausbilder".
  HEADER_LV_2026 = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;\"Kurs 1\n" \
                   "Datum\";Kurs 1 Testversion;\"Kurs 1\nPunkte\";Kurs 2;\"Kurs 2\n" \
                   "Datum\";Kurs 2 Testversion;\"Kurs 2\nPunkte\";Kommentar LV;Ausbilder;" \
                   "Meldedatum LV;Prüfung Daten;Prüfung Kurs;Status FD\n".freeze

  def setup
    @user = create(:user, :admin)
  end

  def call(rows, header: HEADER)
    csv = "#{header}#{rows.join("\n")}\n"
    service = RefereeCourseImportService.new(
      csv_content: csv,
      filename: 'test.csv',
      uploaded_by_user: @user
    )
    service.call
  end

  def service_for(csv)
    RefereeCourseImportService.new(
      csv_content: csv,
      filename: 'test.csv',
      uploaded_by_user: @user
    )
  end

  test 'erkennt 6/6 exakten Match' do
    sa = create(:state_association)
    club = Club.create!(name: 'Floorball-Club München e.V.', state_association_id: sa.id)
    Referee.create!(
      lizenznummer: 520, vorname: 'Sönke', nachname: 'Grimpen',
      geburtsdatum: Date.new(1970, 4, 17),
      email: 'sg@example.de', club_id: club.id
    )

    import = call(['520;Grimpen;Sönke;17.04.1970;Floorball-Club München e.V.;sg@example.de;F;03.08.2025;F-25-2;46;;;;;Johannes Schönmeier'])
    result = import.referee_course_results.first

    assert_equal 'exact_match', result.match_type
    assert_equal 6, result.match_field_count
    assert_equal sa.id, result.state_association_id
  end

  test 'leeres Feld auf einer Seite zählt als Match (symmetrisch)' do
    club = Club.create!(name: 'VfL Kaufering e.V.')
    Referee.create!(
      lizenznummer: 356, vorname: 'Sophia', nachname: 'Dahme',
      geburtsdatum: Date.new(1989, 9, 14),
      email: nil, club_id: club.id
    )

    import = call(['356;Dahme;Sophia;14.09.1989;VfL Kaufering e.V.;;G;03.08.2025;G-25-2;25;;;;;Markus Fischer'])
    result = import.referee_course_results.first

    assert_equal 'exact_match', result.match_type
    assert_equal 6, result.match_field_count
  end

  test 'Teilmatch ≥3 wird als partial_match erkannt' do
    Referee.create!(
      lizenznummer: 700, vorname: 'Max', nachname: 'Müller',
      geburtsdatum: Date.new(1985, 5, 5), email: 'old@example.de'
    )

    import = call(['700;Müller;Max;01.01.1990;Anderer Verein e.V.;new@example.de;G;01.08.2025;G-25-1;30;;;;;Lehrer'])
    result = import.referee_course_results.first

    assert_equal 'partial_match', result.match_type
    assert_includes 3..5, result.match_field_count
  end

  test 'Lizenznummer-Match zwingt in Korrektur-Workflow auch ohne weitere Felder' do
    Referee.create!(
      lizenznummer: 800, vorname: 'Alt', nachname: 'Name',
      geburtsdatum: Date.new(1970, 1, 1)
    )

    import = call(['800;Komplettneu;Vorname;05.05.2000;;new@x.de;G;01.08.2025;G;10;;;;;A'])
    result = import.referee_course_results.first

    assert_equal 'partial_match', result.match_type
    assert_not_nil result.referee_id
  end

  test 'neu wenn keine Übereinstimmung' do
    import = call(['999;Neu;Person;01.01.2000;Unbekannter Verein;np@x.de;G;01.08.2025;G;10;;;;;A'])
    result = import.referee_course_results.first

    assert_equal 'new_entry', result.match_type
    assert_nil result.referee_id
  end

  test 'kursstichtag = max Datum aus Kurs1/Kurs2; gueltigkeit = Stichtag Folgejahr (Regeljahr → 31.07.)' do
    import = call([';X;Y;01.01.2000;;;F;01.08.2025;F;10;G;15.09.2025;G;12;Ausb'])
    result = import.referee_course_results.first

    assert_equal Date.new(2025, 9, 15), result.kursstichtag
    # Kursjahr 2025 + Default-Dauer 1 → Ablaufjahr 2026 ist Regeljahr → 31.07.
    assert_equal Date.new(2026, 7, 31), result.gueltigkeit
  end

  test 'verein wird nur bei exaktem Namens-Match übernommen' do
    sa = create(:state_association)
    Club.create!(name: 'Exakter Name e.V.', state_association_id: sa.id)

    import = call(['999;X;Y;01.01.2000;Exakter Name e.V.;;G;01.08.2025;G;10;;;;;A'])
    result = import.referee_course_results.first
    assert_not_nil result.master_club_id_by_importer
    assert_equal sa.id, result.state_association_id

    import2 = call(['998;X;Y;01.01.2000;Falscher Name;;G;01.08.2025;G;10;;;;;A'])
    result2 = import2.referee_course_results.first
    assert_nil result2.master_club_id_by_importer
    assert_nil result2.state_association_id
  end

  test 'leere Zeilen werden ignoriert' do
    import = call([
      '999;Neu;Person;01.01.2000;;;G;01.08.2025;G;10;;;;;A',
      ';;;;;;;;;;;;;;',
      ';;;;;;;;;;;;;;'
    ])
    assert_equal 1, import.total_rows
  end

  test 'CSV mit BOM wird korrekt geparst' do
    bom = "\xEF\xBB\xBF".dup.force_encoding('UTF-8')
    csv = "#{bom}#{HEADER}999;Neu;Person;01.01.2000;;;G;01.08.2025;G;10;;;;;A\n"
    service = RefereeCourseImportService.new(
      csv_content: csv,
      filename: 'bom.csv',
      uploaded_by_user: @user
    )
    import = service.call
    assert_equal 1, import.total_rows
  end

  test 'LV-Vorlage 2026: Ausbilder wird trotz zusätzlicher Spalte Kommentar LV übernommen' do
    import = call(
      ['356;Dahme;Sophia;14.09.1989;VfL Kaufering e.V.;;G;03.08.2025;G-25-2;25;;;;;' \
       'Kommentar des LV;Markus Fischer;05.08.2025;;;Bearbeitet'],
      header: HEADER_LV_2026
    )
    result = import.referee_course_results.first

    assert_equal 'Markus Fischer', result.course_data['ausbilder']
    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Sophia', result.csv_vorname
    assert_equal Date.new(1989, 9, 14), result.csv_geburtsdatum
    assert_equal 'VfL Kaufering e.V.', result.csv_verein
    assert_equal 'G', result.course_data.dig('kurs_1', 'stufe')
    assert_equal '03.08.2025', result.course_data.dig('kurs_1', 'datum')
    assert_equal 'G-25-2', result.course_data.dig('kurs_1', 'testversion')
    assert_equal '25', result.course_data.dig('kurs_1', 'punkte')
    assert_equal Date.new(2025, 8, 3), result.kursstichtag
  end

  test 'LV-Vorlage 2026 im Original-Format: BOM, CRLF-Datenzeilen, mehrzeilige Header-Zellen' do
    # Genau die Mischung, die Excel exportiert: die Header-Zellen brechen mit LF
    # innerhalb der Quotes um, die Zeilen enden mit CRLF.
    bom  = "\xEF\xBB\xBF".dup.force_encoding('UTF-8')
    csv  = +bom
    # chomp entfernt nur das abschließende LF; die LF innerhalb der Quotes
    # bleiben stehen, die Zeile selbst endet danach mit CRLF.
    csv << HEADER_LV_2026.chomp << "\r\n"
    csv << '356;Dahme;Sophia;14.09.1989;VfL Kaufering e.V.;;G;03.08.2025;G-25-2;25;;;;;;' \
           "Markus Fischer;05.08.2025;;;Bearbeitet\r\n"
    csv << '520;Grimpen;Sönke;17.04.1970;Floorball-Club München e.V.;;F;03.08.2025;F-25-2;46;;;;;;' \
           "Johannes Schönmeier;05.08.2025;;;Bearbeitet\r\n"
    csv << ";;;;;;;;;;;;;;;;;;;\r\n" * 3

    service = service_for(csv)
    import = service.call

    assert_not_nil import, "Import abgewiesen: #{service.errors.join(' ')}"
    assert_equal 2, import.total_rows

    ausbilder = import.referee_course_results.order(:id).map { |r| r.course_data['ausbilder'] }
    assert_equal ['Markus Fischer', 'Johannes Schönmeier'], ausbilder
  end

  test 'LV-Vorlage 2026: Leerzeilen mit 20 Semikolons werden ignoriert' do
    import = call(
      ['356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;;Markus Fischer;05.08.2025;;;',
       ';;;;;;;;;;;;;;;;;;;',
       ';;;;;;;;;;;;;;;;;;;'],
      header: HEADER_LV_2026
    )

    assert_equal 1, import.total_rows
  end

  test 'Header mit eindeutigen Namen in abweichender Reihenfolge wird über Namen aufgelöst' do
    header = "Lizenznummer;Vorname;Name;Geburtsdatum;Ausbilder;Verein;E-Mail Adresse;" \
             "Kurs 1;Kurs 1 Datum;Kurs 1 Testversion;Kurs 1 Punkte\n"
    import = call(['356;Sophia;Dahme;14.09.1989;Markus Fischer;;;G;03.08.2025;G-25-2;25'],
                  header: header)
    result = import.referee_course_results.first

    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Sophia', result.csv_vorname
    assert_equal 'Markus Fischer', result.course_data['ausbilder']
    # Kurs 2 fehlt in dieser Datei komplett → keine geratenen Werte.
    assert_nil result.course_data.dig('kurs_2', 'stufe')
  end

  test 'Header ohne Pflichtspalten wird mit Fehlermeldung abgewiesen' do
    csv = "Lizenznummer;Nachname-Feld;Rufname;Verein;Kurs 1;Kurs 1 Datum\n" \
          "356;Dahme;Sophia;VfL Kaufering e.V.;G;03.08.2025\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/Pflichtspalten/, service.errors.join(' '))
    assert_match(/Vorname/, service.errors.join(' '))
    assert_match(/Geburtsdatum/, service.errors.join(' '))
  end

  test 'mehrdeutiger Header mit abweichender Spaltenzahl wird abgewiesen' do
    csv = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
          "Kurs 1 Testversion;Kurs 1;Kommentar LV;Ausbilder\n" \
          "356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;Markus Fischer\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/nicht eindeutig/, service.errors.join(' '))
  end

  test 'parses umlauts in club names without raising' do
    club = Club.create!(name: 'Verein Müller-Lüdenscheidt e.V.')
    Referee.create!(
      lizenznummer: 600, vorname: 'A', nachname: 'B',
      geburtsdatum: Date.new(1990, 1, 1), club_id: club.id
    )

    import = call(['600;B;A;01.01.1990;Verein Müller-Lüdenscheidt e.V.;;G;01.08.2025;G;10;;;;;A'])
    result = import.referee_course_results.first
    assert_equal club.id, result.master_club_id_by_importer
  end
end
