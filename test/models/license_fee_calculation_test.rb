require 'test_helper'

class LicenseFeeCalculationTest < ActiveSupport::TestCase
  # Der Nachtrag des Bundeslands zu Beginn der Berechnung.
  #
  # Die Zeile stand bis 1.86.0 als Club#update_state am Modell und war seit dem
  # Rails-Upgrade kaputt (`update_attributes`), ohne dass ein Test es gemerkt
  # haette: start_calculation ist ungetestet, weil es Dateien schreibt und ueber
  # alle Spieler laeuft.
  test 'traegt das Bundesland aus der PLZ nach' do
    club = create(:club, postcode: '44135', state: nil)

    LicenseFeeCalculation.backfill_missing_club_states

    assert_equal 'de-nw', club.reload.state
  end

  test 'laesst ein bereits gepflegtes Bundesland unangetastet' do
    # Auch dann, wenn die PLZ etwas anderes sagt: von Hand gepflegte Angaben
    # gewinnen, der Nachtrag fuellt nur Luecken.
    club = create(:club, postcode: '44135', state: 'de-he')

    LicenseFeeCalculation.backfill_missing_club_states

    assert_equal 'de-he', club.reload.state
  end

  test 'ueberspringt Vereine ohne bestimmbares Bundesland' do
    ohne_plz = create(:club, postcode: nil, state: nil)
    auslaendisch = create(:club, postcode: '8001', state: nil)

    assert_nothing_raised { LicenseFeeCalculation.backfill_missing_club_states }

    assert_nil ohne_plz.reload.state
    assert_nil auslaendisch.reload.state
  end
end
