require 'test_helper'
require Rails.root.join('db/migrate/20260708120000_change_players_birthdate_to_date')

# Normalisierungslogik der birthdate-Migration: ISO bleibt, deutsches Format
# wird umgeschrieben, Leer-/Nullwerte werden zu nil, alles andere ist :invalid
# (die Migration bricht dann ab, statt Daten still zu nullen).
class ChangePlayersBirthdateToDateTest < ActiveSupport::TestCase
  def normalize(value)
    ChangePlayersBirthdateToDate.normalize(value)
  end

  test 'ISO-Werte bleiben unverändert (inkl. Whitespace-Trim)' do
    assert_equal '1990-01-01', normalize('1990-01-01')
    assert_equal '1990-01-01', normalize(' 1990-01-01 ')
  end

  test 'deutsches Format wird nach ISO umgeschrieben' do
    assert_equal '2010-02-01', normalize('01.02.2010')
    assert_equal '2010-02-01', normalize('1.2.2010')
  end

  test 'leere Werte und MariaDB-Nulldaten werden zu nil' do
    assert_nil normalize(nil)
    assert_nil normalize('')
    assert_nil normalize('   ')
    assert_nil normalize('0000-00-00')
  end

  test 'unlesbare Werte sind :invalid' do
    assert_equal :invalid, normalize('2010-02-30'), 'ungültiges Kalenderdatum'
    assert_equal :invalid, normalize('31.02.2010'), 'ungültiges Kalenderdatum (deutsch)'
    assert_equal :invalid, normalize('1990-1-1'), 'nicht-kanonisches ISO wird nicht geraten'
    assert_equal :invalid, normalize('05/17/1990')
    assert_equal :invalid, normalize('unbekannt')
  end
end
