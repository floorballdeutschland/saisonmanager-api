require 'test_helper'

class RefereeAvailabilityTest < ActiveSupport::TestCase
  def setup
    @referee = create(:referee)
  end

  test 'erlaubt den heutigen Tag' do
    assert RefereeAvailability.new(referee: @referee, date: Date.today).valid?
  end

  test 'erlaubt zukünftige Tage' do
    assert RefereeAvailability.new(referee: @referee, date: Date.today + 5).valid?
  end

  test 'lehnt vergangene Tage ab' do
    availability = RefereeAvailability.new(referee: @referee, date: Date.today - 1)
    refute availability.valid?
    assert_includes availability.errors[:date], 'darf nicht in der Vergangenheit liegen'
  end
end
