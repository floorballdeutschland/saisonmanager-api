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

  test 'vierstellige auslaendische PLZ ergibt kein Bundesland' do
    # Die Tabelle fuehrt fuehrende Nullen als kleinere Zahl (Sachsen steht als
    # 8001..9669), eine vierstellige PLZ trifft also einen echten Bereich. Ohne
    # die Fuenfstelligkeits-Pruefung wird aus Zuerich Sachsen und aus Innsbruck
    # Sachsen-Anhalt – und ab #468 haengt daran eine Berechtigung.
    assert_nil ApplicationRecord.state_for_postcode('8001')
    assert_nil ApplicationRecord.state_for_postcode('9000')
    assert_nil ApplicationRecord.state_for_postcode('6020')
    assert_nil ApplicationRecord.state_for_postcode('3000')
  end

  test 'mehrfach belegte PLZ folgt der Reihenfolge der Tabelle' do
    # 21039 und 22145 liegen sowohl in Schleswig-Holstein als auch in Hamburg.
    # Welches gewinnt, folgt allein aus der Reihenfolge des Literals; wer die
    # Tabelle einmal sortiert, kippt das Ergebnis lautlos.
    assert_equal 'de-sh', ApplicationRecord.state_for_postcode('21039')
    assert_equal 'de-sh', ApplicationRecord.state_for_postcode('22145')
  end

  test 'Bereich ohne isocode ergibt nil statt eines Fehlers' do
    # Jungholz und Kleinwalsertal tragen nur `region: 'Ausserhalb der BRD'`.
    assert_nil ApplicationRecord.state_for_postcode('87491')
    assert_nil ApplicationRecord.state_for_postcode('87568')
  end

  test 'german_states listet genau die 16 Bundeslaender' do
    # Vollstaendig festgenagelt und nicht per Stichprobe: dieselbe Liste steht
    # zwangslaeufig ein zweites Mal im Frontend (german-states.spec.ts haelt sie
    # dort fest), weil dort zusaetzlich die Klartextnamen gebraucht werden.
    # Laeuft eine der beiden Seiten weg, wird ein gueltiges Bundesland beim
    # Speichern als unbekannt abgewiesen. Dieser Vergleich macht daraus einen
    # roten Test statt einer Ueberraschung in der Maske.
    assert_equal %w[de-bb de-be de-bw de-by de-hb de-he de-hh de-mv
                    de-ni de-nw de-rp de-sh de-sl de-sn de-st de-th],
                 ApplicationRecord.german_states
    # Waechter gegen ein Zurueckdrehen von filter_map auf map.
    assert_not_includes ApplicationRecord.german_states, nil
  end
end
