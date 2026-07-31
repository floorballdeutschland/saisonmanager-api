require 'test_helper'

# Die Anwendung nutzt I18n ausschließlich zum Formatieren von Datum und Uhrzeit.
# Diese Tests halten beides fest: dass die Ausgabe deutsch ist, und dass der
# Fallback auf :en die Meldungen aus ActiveRecord/ActiveModel weiter liefert
# (dafür gibt es keine deutschen Übersetzungen).
class I18nDateFormatsTest < ActiveSupport::TestCase
  DATE = Date.new(2026, 1, 10).freeze

  test 'Default-Locale ist Deutsch' do
    assert_equal :de, I18n.default_locale
  end

  test 'Fallback zeigt auf Englisch, nicht auf sich selbst' do
    # `fallbacks = true` hätte auf die Default-Locale zurückgefallen – seit die
    # :de ist, wäre die Kette bei sich selbst geendet und die englischen
    # Rails-Meldungen unerreichbar geworden.
    assert_includes I18n.fallbacks[:de], :en
  end

  test 'langes Datumsformat schreibt den Monat deutsch aus' do
    assert_equal '10. Januar 2026', I18n.l(DATE, format: :long).strip
  end

  test 'Standard- und Kurzformat sind deutsch' do
    assert_equal '10.01.2026', I18n.l(DATE)
    assert_equal '10.01.', I18n.l(DATE, format: :short)
  end

  test 'Uhrzeitformate sind deutsch' do
    time = Time.zone.local(2026, 1, 10, 14, 30)

    assert_equal '10.01.2026 14:30', I18n.l(time)
    assert_equal '10. Januar 2026 14:30', I18n.l(time, format: :long).strip
  end

  test 'alle Monatsnamen sind hinterlegt' do
    names = I18n.t('date.month_names')

    assert_equal 13, names.length, 'Rails erwartet einen Leereintrag an Position 0'
    assert_nil names.first
    assert_equal 'März', names[3]
    assert_equal 'Dezember', names[12]
  end

  test 'Wochentage sind hinterlegt' do
    assert_equal 'Samstag', I18n.t('date.day_names')[6]
    assert_equal 'Sa', I18n.t('date.abbr_day_names')[6]
  end

  test 'Fehlermeldungen bleiben ueber den Fallback erreichbar' do
    # Ohne Fallback stünde hier „translation missing", und zwar in jeder
    # Validierungsmeldung der API. StateAssociation verlangt einen Namen.
    record = StateAssociation.new

    assert_not record.valid?
    assert record.errors.full_messages.any?
    refute_includes record.errors.full_messages.join(' '), 'translation missing'
  end
end
