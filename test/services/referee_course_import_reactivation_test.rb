require 'test_helper'

# Trifft ein Kursergebnis einen Schiedsrichter mit beendeter Karriere, ist das
# eine Reaktivierung der alten Lizenznummer. Ohne Hinweis sähe die LV-Prüfansicht
# einen unauffälligen Treffer.
class RefereeCourseImportReactivationTest < ActiveSupport::TestCase
  HEADER = "Lizenznummer;Name;Vorname;Geburtsdatum;Verein;E-Mail Adresse;Kurs 1;Kurs 1;" \
           "Kurs 1 Testversion;Kurs 1;Kurs 2;Kurs 2;Kurs 2 Testversion;Kurs 2;Ausbilder\n".freeze

  def setup
    Rails.cache.clear
    create(:setting, current_season_id: '19')
    Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
    Rails.cache.clear
    @user = create(:user, :admin)
  end

  def import_row(row)
    RefereeCourseImportService.new(
      csv_content: "#{HEADER}#{row}\n", filename: 'test.csv', uploaded_by_user: @user
    ).call.referee_course_results.first
  end

  def reactivation_warnings(result)
    result.import_warnings.select { |w| w['reason'].to_s.include?('Karriere beendet') }
  end

  test 'Reaktivierung einer beendeten Lizenznummer wird gemeldet' do
    Referee.create!(lizenznummer: 4711, vorname: 'Rudi', nachname: 'Rueckkehr',
                    geburtsdatum: Date.new(1980, 5, 5), gueltigkeit: Date.new(2016, 9, 30))

    result = import_row('4711;Rueckkehr;Rudi;05.05.1980;;;F;03.08.2026;F-26-1;46;;;;;Ausbilder')

    warnings = reactivation_warnings(result)

    assert_equal 1, warnings.size
    assert_match(/abgelaufen am 30\.09\.2016/, warnings.first['reason'])
    assert_match(/Grundkurs erforderlich/, warnings.first['reason'])
    assert_equal '4711', warnings.first['raw']
  end

  test 'abgelaufene, aber nicht beendete Lizenz löst keinen Hinweis aus' do
    Referee.create!(lizenznummer: 4712, vorname: 'Lars', nachname: 'Laufzeit',
                    geburtsdatum: Date.new(1980, 5, 5), gueltigkeit: Date.new(2023, 9, 30))

    result = import_row('4712;Laufzeit;Lars;05.05.1980;;;F;03.08.2026;F-26-1;46;;;;;Ausbilder')

    assert_empty reactivation_warnings(result)
  end

  test 'Neuanlage löst keinen Hinweis aus' do
    result = import_row('4713;Neuling;Nina;05.05.2000;;;F;03.08.2026;F-26-1;46;;;;;Ausbilder')

    assert_equal 'new_entry', result.match_type
    assert_empty reactivation_warnings(result)
  end
end
