require 'test_helper'

class RefereeEmailImportTest < ActiveSupport::TestCase
  def csv(rows, header: 'Lizenznummer;E-Mailadresse', sep: ';')
    ([header] + rows.map { |r| r.join(sep) }).join("\n")
  end

  test 'traegt die Adresse ein, wo noch keine steht' do
    referee = create(:referee, lizenznummer: 4711, email: nil)

    report = RefereeEmailImport.new(csv_content: csv([[4711, 'neu@example.org']])).call

    assert_equal 'neu@example.org', referee.reload.email
    assert_equal 1, report[:updated].size
    assert_equal 4711, report[:updated].first[:lizenznummer]
  end

  test 'laesst eine vorhandene Adresse unberuehrt' do
    referee = create(:referee, lizenznummer: 4712, email: 'alt@example.org')

    report = RefereeEmailImport.new(csv_content: csv([[4712, 'neu@example.org']])).call

    assert_equal 'alt@example.org', referee.reload.email
    assert_equal 0, report[:updated].size
    assert_equal 'other_email', report[:skipped].first[:reason]
    assert_equal 'neu@example.org', report[:skipped].first[:csv_email]
  end

  test 'meldet die identische Adresse getrennt von einer abweichenden' do
    create(:referee, lizenznummer: 4713, email: 'gleich@example.org')

    report = RefereeEmailImport.new(csv_content: csv([[4713, 'GLEICH@example.org']])).call

    assert_equal 'identical', report[:skipped].first[:reason]
  end

  test 'meldet unbekannte Lizenznummern' do
    report = RefereeEmailImport.new(csv_content: csv([[999_111, 'x@example.org']])).call

    assert_equal [999_111], report[:not_found]
    assert_equal 0, report[:updated].size
  end

  test 'schreibt nichts bei nicht-numerischer Lizenznummer' do
    referee = create(:referee, lizenznummer: 12, email: nil)

    report = RefereeEmailImport.new(csv_content: csv([['12a', 'x@example.org']])).call

    assert_nil referee.reload.email
    assert_equal 1, report[:invalid].size
    assert_equal 'Lizenznummer ist keine Zahl', report[:invalid].first[:reason]
  end

  test 'weist ungueltige Adressen ab' do
    referee = create(:referee, lizenznummer: 4714, email: nil)

    report = RefereeEmailImport.new(csv_content: csv([[4714, 'kein-at-zeichen']])).call

    assert_nil referee.reload.email
    assert_equal 'E-Mailadresse ist ungültig', report[:invalid].first[:reason]
  end

  test 'zweite Zeile zur gleichen Lizenznummer ueberschreibt die erste nicht' do
    referee = create(:referee, lizenznummer: 4715, email: nil)

    report = RefereeEmailImport.new(
      csv_content: csv([[4715, 'erste@example.org'], [4715, 'zweite@example.org']])
    ).call

    assert_equal 'erste@example.org', referee.reload.email
    assert_equal 1, report[:updated].size
    assert_equal 'other_email', report[:skipped].first[:reason]
  end

  test 'erkennt Komma als Trennzeichen' do
    referee = create(:referee, lizenznummer: 4716, email: nil)

    report = RefereeEmailImport.new(
      csv_content: csv([[4716, 'komma@example.org']], header: 'Lizenznummer,E-Mailadresse', sep: ',')
    ).call

    assert_equal 'komma@example.org', referee.reload.email
    assert_equal 1, report[:updated].size
  end

  test 'liest eine Datei mit BOM und CRLF' do
    referee = create(:referee, lizenznummer: 4717, email: nil)
    content = "\u{FEFF}Lizenznummer;E-Mailadresse\r\n4717;bom@example.org\r\n"

    RefereeEmailImport.new(csv_content: content).call

    assert_equal 'bom@example.org', referee.reload.email
  end

  test 'erkennt Spaltenueberschriften unabhaengig von Schreibweise' do
    referee = create(:referee, lizenznummer: 4718, email: nil)
    content = "LIZENZNUMMER ; E-Mail-Adresse\n4718;alias@example.org\n"

    RefereeEmailImport.new(csv_content: content).call

    assert_equal 'alias@example.org', referee.reload.email
  end

  test 'weist die Datei ohne Pflichtspalten ab' do
    import = RefereeEmailImport.new(csv_content: "Nummer;Adresse\n1;a@example.org\n")

    assert_nil import.call
    assert_match(/Pflichtspalten/, import.errors.join)
  end

  test 'weist eine Datei ohne Datenzeilen ab' do
    import = RefereeEmailImport.new(csv_content: "Lizenznummer;E-Mailadresse\n")

    assert_nil import.call
    assert_match(/keine Datenzeilen/, import.errors.join)
  end

  test 'weist ein nicht lesbares Encoding mit Hinweis ab' do
    import = RefereeEmailImport.new(csv_content: "Lizenznummer;E-Mailadresse\n1;M\xFCller@example.org\n")

    assert_nil import.call
    assert_match(/UTF-8/, import.errors.join)
  end

  # Die Zeilennummer im Report muss auf die Zeile in der Tabellenkalkulation
  # zeigen. Eine verworfene Leerzeile darf sie nicht verschieben.
  test 'nennt die Zeilennummer der Datei auch nach einer Leerzeile' do
    create(:referee, lizenznummer: 4730, email: nil)
    create(:referee, lizenznummer: 4731, email: nil)
    content = "Lizenznummer;E-Mailadresse\n4730;a@example.org\n\n4731;kaputt\n"

    report = RefereeEmailImport.new(csv_content: content).call

    assert_equal 4, report[:invalid].first[:row]
  end

  # Die vier Toepfe muessen total_rows ergeben, sonst luegt die
  # Zusammenfassung ueber einen bereits geschriebenen Datenbestand.
  test 'jede Datenzeile landet in genau einem Topf' do
    create(:referee, lizenznummer: 4740, email: nil)
    create(:referee, lizenznummer: 4741, email: 'da@example.org')
    content = "Lizenznummer;E-Mailadresse\n" \
              "4740;neu@example.org\n" \
              "4741;andere@example.org\n" \
              "999222;unbekannt@example.org\n" \
              "4740x;kaputt@example.org\n"

    report = RefereeEmailImport.new(csv_content: content).call

    assert_equal 4, report[:total_rows]
    buckets = report.values_at(:updated, :skipped, :not_found, :invalid)
    assert_equal report[:total_rows], buckets.sum(&:size)
  end

  test 'zaehlt Leerzeilen nicht als Datenzeilen' do
    create(:referee, lizenznummer: 4750, email: nil)
    content = "Lizenznummer;E-Mailadresse\n\n4750;a@example.org\n\n"

    report = RefereeEmailImport.new(csv_content: content).call

    assert_equal 1, report[:total_rows]
    assert_equal 1, report[:updated].size
  end

  test 'weist eine Datei mit zu vielen Datenzeilen ab' do
    rows = (1..(RefereeEmailImport::MAX_DATA_ROWS + 1)).map { |n| "#{n};a#{n}@example.org" }
    import = RefereeEmailImport.new(csv_content: (['Lizenznummer;E-Mailadresse'] + rows).join("\n"))

    assert_nil import.call
    assert_match(/hoechstens|höchstens/, import.errors.join)
  end

  test 'meldet eine leere Adress-Zelle als eigene Zeile' do
    referee = create(:referee, lizenznummer: 4760, email: nil)

    report = RefereeEmailImport.new(csv_content: csv([[4760, '']])).call

    assert_nil referee.reload.email
    assert_equal 'E-Mailadresse fehlt', report[:invalid].first[:reason]
  end

  test 'erkennt Tabulator als Trennzeichen' do
    referee = create(:referee, lizenznummer: 4770, email: nil)

    report = RefereeEmailImport.new(
      csv_content: csv([[4770, 'tab@example.org']], header: "Lizenznummer\tE-Mailadresse", sep: "\t")
    ).call

    assert_equal 'tab@example.org', referee.reload.email
    assert_equal 1, report[:updated].size
  end

  # Der Fehler sitzt dann im Stammdatensatz, nicht in der CSV-Zeile - die Meldung
  # muss den Schiedsrichter benennen, sonst sucht der Admin in der Datei.
  test 'benennt bei einem ungueltigen Stammdatensatz den Schiedsrichter' do
    referee = create(:referee, lizenznummer: 4780, email: nil)
    referee.update_column(:vorname, '')

    report = RefereeEmailImport.new(csv_content: csv([[4780, 'neu@example.org']])).call

    assert_equal 0, report[:updated].size
    assert_equal 1, report[:invalid].size
    assert_includes report[:invalid].first[:value], '4780'
  end

  test 'schreibt nicht an einen zusammengefuehrten Datensatz' do
    master = create(:referee, lizenznummer: 4719, email: nil)
    secondary = create(:referee, lizenznummer: 4720, email: nil)
    secondary.merge_into!(master)

    report = RefereeEmailImport.new(csv_content: csv([[4720, 'dublette@example.org']])).call

    assert_nil secondary.reload.email
    assert_equal [4720], report[:not_found]
  end
end
