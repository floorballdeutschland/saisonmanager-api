require 'test_helper'

class RefereeCourseImportServiceTest < ActiveSupport::TestCase
  HEADER = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
           "Kurs 1 Testversion;Kurs 1;Kurs 2;Kurs 2;Kurs 2 Testversion;Kurs 2;Ausbilder\n".freeze

  def setup
    @user = create(:user, :admin)
  end

  def call(rows)
    csv = "#{HEADER}#{rows.join("\n")}\n"
    service = RefereeCourseImportService.new(
      csv_content: csv,
      filename: 'test.csv',
      uploaded_by_user: @user
    )
    service.call
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

  test 'kursstichtag = max Datum aus Kurs1/Kurs2; gueltigkeit = 30.9. Folgejahr' do
    import = call([';X;Y;01.01.2000;;;F;01.08.2025;F;10;G;15.09.2025;G;12;Ausb'])
    result = import.referee_course_results.first

    assert_equal Date.new(2025, 9, 15), result.kursstichtag
    assert_equal Date.new(2026, 9, 30), result.gueltigkeit
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
