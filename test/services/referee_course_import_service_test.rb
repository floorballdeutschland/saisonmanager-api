require 'test_helper'

class RefereeCourseImportServiceTest < ActiveSupport::TestCase
  # Alt-Vorlage: Stufe, Datum und Punkte teilen sich denselben Namen, der Header
  # ist damit nicht eindeutig auflösbar → positionaler Fallback.
  HEADER = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
           "Kurs 1 Testversion;Kurs 1;Kurs 2;Kurs 2;Kurs 2 Testversion;Kurs 2;Ausbilder\n".freeze

  # LV-Vorlage 2026: 20 eindeutige Überschriften, vier davon in Quotes über zwei
  # Zeilen umgebrochen, dazu fünf LV-Arbeitsspalten — „Kommentar LV" steht vor
  # „Ausbilder". Achtung: die Konstante endet mit LF, ist also noch nicht das
  # Excel-Byte-Layout; die CRLF-Mischung stellt nur der Original-Format-Test her.
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
    # Die LF innerhalb der Quotes bleiben stehen; nur der Zeilenabschluss wird
    # auf CRLF gedreht.
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

  test 'doppelte Kurs-Ueberschriften ausserhalb der Alt-Vorlage werden abgewiesen' do
    # Alt-Vorlagen-Ueberschriften, aber abweichende Breite: die drei „Kurs 1"
    # sind nicht auflösbar und die Positionen nicht verlässlich. Die Datei wird
    # abgewiesen, statt geraten zu werden.
    csv = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
          "Kurs 1 Testversion;Kurs 1;Kommentar LV;Ausbilder\n" \
          "356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;Markus Fischer\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/Kurs 1/, service.errors.join(' '))
  end

  # --- Alt-Vorlage: positionaler Pfad vollständig festnageln ---------------

  test 'Alt-Vorlage: alle positional gelesenen Felder landen richtig' do
    import = call([
      '356;Dahme;Sophia;14.09.1989;VfL Kaufering e.V.;sd@x.de;' \
      'G;03.08.2025;G-25-2;25;F;15.09.2025;F-25-1;46;Markus Fischer'
    ])
    result = import.referee_course_results.first

    assert_equal 356, result.csv_lizenznummer
    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Sophia', result.csv_vorname
    assert_equal Date.new(1989, 9, 14), result.csv_geburtsdatum
    assert_equal 'VfL Kaufering e.V.', result.csv_verein
    assert_equal 'sd@x.de', result.csv_email
    assert_equal 'Markus Fischer', result.course_data['ausbilder']
    assert_equal({ 'stufe' => 'G', 'datum' => '03.08.2025', 'testversion' => 'G-25-2',
                   'punkte' => '25' }, result.course_data['kurs_1'])
    assert_equal({ 'stufe' => 'F', 'datum' => '15.09.2025', 'testversion' => 'F-25-1',
                   'punkte' => '46' }, result.course_data['kurs_2'])
  end

  test 'Alt-Vorlage mit angehängter Leerspalte bleibt positional lesbar' do
    # Excel exportiert die benutzte Range und hängt dabei gern eine angefasste
    # Leerspalte an. Die darf die Erkennung der Alt-Vorlage nicht kippen.
    header = "#{HEADER.chomp};\n"
    import = call(['356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;Markus Fischer;'],
                  header: header)
    result = import.referee_course_results.first

    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Markus Fischer', result.course_data['ausbilder']
  end

  # --- Grenze zwischen Namens-Auflösung und positionalem Fallback ----------

  test '15 Spalten mit eindeutigen Namen werden per Namen gelesen, nicht positional' do
    # Gleiche Breite wie die Alt-Vorlage, aber Vorname vor Name. Positional
    # gelesen wären Vor- und Nachname vertauscht.
    header = "Lizenznummer;Vorname;Name;Geburtsdatum;Verein;E-Mail Adresse;" \
             "Kurs 1;Kurs 1 Datum;Kurs 1 Testversion;Kurs 1 Punkte;" \
             "Kurs 2;Kurs 2 Datum;Kurs 2 Testversion;Kurs 2 Punkte;Ausbilder\n"
    import = call(['356;Sophia;Dahme;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;Markus Fischer'],
                  header: header)
    result = import.referee_course_results.first

    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Sophia', result.csv_vorname
  end

  test '15 Spalten mit umbenannter Pflichtspalte werden abgewiesen statt positional gelesen' do
    # Frueher: Spaltenzahl 15 → positionaler Fallback → hier stand dann das
    # Meldedatum im Ausbilder-Feld und niemand erfuhr davon.
    csv = "Lizenznummer;Name;Vorname;Geburtstag;Verein;E-Mail Adresse;" \
          "Kurs 1;Kurs 1 Datum;Kurs 1 Testversion;Kurs 1 Punkte;" \
          "Kurs 2;Kurs 2 Datum;Kommentar LV;Ausbilder;Meldedatum LV\n" \
          "356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;Markus Fischer;05.08.2025\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/Pflichtspalten/, service.errors.join(' '))
    assert_match(/Geburtsdatum/, service.errors.join(' '))
  end

  test 'Zeile 1 ohne Ueberschriften wird nicht als Alt-Vorlage positional gelesen' do
    csv = "356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;Markus Fischer\n" \
          "520;Grimpen;Sönke;17.04.1970;;;F;03.08.2025;F-25-2;46;;;;;Ausb\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/Pflichtspalten/, service.errors.join(' '))
  end

  # --- Weitere stille Fehlerquellen ---------------------------------------

  test 'geschuetztes Leerzeichen in der Ueberschrift bricht die Zuordnung nicht' do
    header = HEADER_LV_2026.gsub('Kurs 1 Testversion', "Kurs 1 Testversion")
                           .gsub('Ausbilder', "Ausbilder ")
    import = call(
      ['356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;;Markus Fischer;;;;'],
      header: header
    )
    result = import.referee_course_results.first

    assert_equal 'Markus Fischer', result.course_data['ausbilder']
    assert_equal 'G-25-2', result.course_data.dig('kurs_1', 'testversion')
  end

  test 'Kursblock ohne erkennbare Datumsspalte wird abgewiesen' do
    # Sonst faellt kursstichtag auf das Kurs-1-Datum zurueck und die Lizenz
    # bekaeme eine zu kurze Gueltigkeit, ohne dass es auffaellt.
    csv = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;" \
          "Kurs 1;Kurs 1 Datum;Kurs 1 Testversion;Kurs 1 Punkte;" \
          "Kurs 2;Datum Kurs 2;Kurs 2 Testversion;Kurs 2 Punkte;Ausbilder;Kommentar LV\n" \
          "356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;F;20.09.2025;F-25-1;46;Ausb;\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/Kurs 2/, service.errors.join(' '))
    assert_match(/Datumsspalte/, service.errors.join(' '))
  end

  test 'zweistelliges Jahr wird verworfen statt als Jahr 25 uebernommen' do
    import = call([';Dahme;Sophia;14.09.89;;;G;03.08.25;G-25-2;25;;;;;Ausb'])
    result = import.referee_course_results.first

    assert_nil result.csv_geburtsdatum
    assert_nil result.kursstichtag
    assert_nil result.gueltigkeit
    reasons = result.import_warnings.map { |w| w['field'] }
    assert_includes reasons, 'geburtsdatum'
  end

  test 'Datei in Windows-1252 wird mit verstaendlicher Meldung abgewiesen' do
    utf8 = "#{HEADER}356;Sönke;Sophia;14.09.1989;;;G;03.08.2025;G;25;;;;;A\n"
    csv = utf8.encode('Windows-1252').force_encoding('UTF-8')
    service = service_for(csv)

    assert_nil service.call
    assert_match(/UTF-8/, service.errors.join(' '))
  end

  test 'Mehrdeutigkeit in einer Wahlspalte verwirft nur dieses Feld' do
    header = HEADER_LV_2026.sub('Kommentar LV', 'E-Mail')
    import = call(
      ['356;Dahme;Sophia;14.09.1989;;sd@x.de;G;03.08.2025;G-25-2;25;;;;;zweite@x.de;' \
       'Markus Fischer;;;;'],
      header: header
    )
    result = import.referee_course_results.first

    assert_nil result.csv_email, 'mehrdeutige E-Mail-Spalte darf nicht geraten werden'
    assert_equal 'Dahme', result.csv_nachname
    assert_equal 'Markus Fischer', result.course_data['ausbilder']
  end

  test 'Mehrdeutigkeit in einer Pflichtspalte bricht ab' do
    header = HEADER_LV_2026.sub('Kommentar LV', 'Nachname')
    csv = "#{header}356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;Meier;Ausb;;;;\n"
    service = service_for(csv)

    assert_nil service.call
    assert_match(/nicht eindeutig/, service.errors.join(' '))
    assert_match(/Name/, service.errors.join(' '))
  end

  test 'Zeile mit Inhalt nur in einer nicht ausgewerteten Spalte gilt als leer' do
    import = call(
      ['356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;;Ausb;;;;',
       ';;;;;;;;;;;;;;Nur eine Notiz des LV;;;;;'],
      header: HEADER_LV_2026
    )

    assert_equal 1, import.total_rows
  end

  test 'Zeilenumbruch innerhalb einer Datenzelle zerreisst die Zeile nicht' do
    csv = +"#{HEADER_LV_2026.chomp}\r\n"
    csv << '356;Dahme;Sophia;14.09.1989;;;G;03.08.2025;G-25-2;25;;;;;' \
           "\"Notiz Zeile 1\r\nNotiz Zeile 2\";Markus Fischer;;;;\r\n"
    service = service_for(csv)
    import = service.call

    assert_not_nil import, "Import abgewiesen: #{service.errors.join(' ')}"
    assert_equal 1, import.total_rows
    assert_equal 'Markus Fischer', import.referee_course_results.first.course_data['ausbilder']
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
