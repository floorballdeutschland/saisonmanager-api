require 'test_helper'

# Geteilte PLZ-Ableitung (#468). Vorher stand sie dreimal im Code, einmal davon
# mit strikten Vergleichen, die Bereichsgrenzen verfehlen.
class ApplicationRecordPostcodeStateTest < ActiveSupport::TestCase
  test 'PLZ mitten im Bereich' do
    assert_equal 'de-nw', ApplicationRecord.state_for_postcode('44135')
    assert_equal 'de-by', ApplicationRecord.state_for_postcode('80331')
  end

  test 'PLZ genau auf der Bereichsgrenze zaehlt mit' do
    # Der alte Vergleich (from < n && till > n) liess genau diese durchfallen:
    # 09669 ist das `till` von 08001..09669.
    assert_equal 'de-sn', ApplicationRecord.state_for_postcode('09669')
    assert_equal 'de-th', ApplicationRecord.state_for_postcode('98501')
  end

  test 'fuehrende Null und Leerzeichen stoeren nicht' do
    assert_equal 'de-sn', ApplicationRecord.state_for_postcode(' 01067 ')
  end

  test 'fehlende oder unplausible PLZ ergibt nil' do
    assert_nil ApplicationRecord.state_for_postcode(nil)
    assert_nil ApplicationRecord.state_for_postcode('')
    assert_nil ApplicationRecord.state_for_postcode('Musterstadt')
    assert_nil ApplicationRecord.state_for_postcode('99999')
  end

  test 'Bereich ohne isocode ergibt nil statt eines Fehlers' do
    # Jungholz und Kleinwalsertal tragen nur `region: 'Ausserhalb der BRD'`.
    assert_nil ApplicationRecord.state_for_postcode('87491')
    assert_nil ApplicationRecord.state_for_postcode('87568')
  end

  test 'german_states listet die 16 Bundeslaender ohne nil' do
    states = ApplicationRecord.german_states

    assert_equal 16, states.size
    assert_equal states.sort, states
    assert_not_includes states, nil
    assert_includes states, 'de-nw'
    assert_not_includes states, 'de-sonstige'
  end
end
