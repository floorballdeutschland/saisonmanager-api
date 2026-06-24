require 'test_helper'

class RefereeLicenseLevelTest < ActiveSupport::TestCase
  test 'gueltigkeit_for nutzt validity_years der Stufe und ankert auf den 30.09.' do
    RefereeLicenseLevel.create!(name: 'L1', validity_years: 2)
    RefereeLicenseLevel.create!(name: 'L3', validity_years: 1)

    # 2 Jahre: Kurs 2026 → 30.09.2028
    assert_equal Date.new(2028, 9, 30), RefereeLicenseLevel.gueltigkeit_for('L1', Date.new(2026, 8, 1))
    # 1 Jahr, Kurs nach dem 30.09. → trotzdem 30.09. des Folgejahres
    assert_equal Date.new(2027, 9, 30), RefereeLicenseLevel.gueltigkeit_for('L3', Date.new(2026, 10, 5))
  end

  test 'gueltigkeit_for nutzt die Default-Dauer bei unbekannter Stufe' do
    assert_equal Date.new(2028, 9, 30), RefereeLicenseLevel.gueltigkeit_for('UNBEKANNT', Date.new(2026, 3, 1))
  end

  test 'gueltigkeit_for liefert nil ohne Ausstellungsdatum' do
    assert_nil RefereeLicenseLevel.gueltigkeit_for('L1', nil)
  end

  test 'validity_years muss eine ganze Zahl >= 1 sein' do
    refute RefereeLicenseLevel.new(name: 'X', validity_years: 0).valid?
    assert RefereeLicenseLevel.new(name: 'Y', validity_years: 1).valid?
  end
end
