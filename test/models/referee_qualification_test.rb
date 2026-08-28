require 'test_helper'

# Eine Zusatzqualifikation gibt es je Schiedsrichter genau einmal: Die zweite
# Zeile waere keine zweite Qualifikation, sondern ein zweites Ablaufdatum fuer
# dieselbe -- und seit der Stufenfilter die Qualifikationen mitliest, stuende
# der Schiedsrichter damit doppelt in der Trefferliste.
class RefereeQualificationTest < ActiveSupport::TestCase
  setup do
    @referee = create(:referee, lizenznummer: 730_001)
    @type = RefereeQualificationType.create!(name: "Beobachter #{SecureRandom.hex(4)}", short_name: 'BEO')
    RefereeQualification.create!(referee: @referee, referee_qualification_type: @type)
  end

  test 'dieselbe Qualifikation laesst sich kein zweites Mal anlegen' do
    doppelt = RefereeQualification.new(referee: @referee, referee_qualification_type: @type)

    assert_not doppelt.valid?
  end

  # Die Validierung greift nur dort, wo ueber das Modell geschrieben wird. Die
  # Zusammenfuehrung zweier Schiedsrichterprofile schiebt die Qualifikationen
  # dagegen mit `update_all` um, also an jeder Validierung vorbei.
  test 'die Datenbank weist die Dublette auch ohne Validierung ab' do
    doppelt = RefereeQualification.new(referee: @referee, referee_qualification_type: @type)

    assert_raises(ActiveRecord::RecordNotUnique) { doppelt.save!(validate: false) }
  end
end
