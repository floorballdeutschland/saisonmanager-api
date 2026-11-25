require 'test_helper'

class GameStartTimeSortKeyTest < ActiveSupport::TestCase
  test 'rechnet in Minuten, mit und ohne führende Null' do
    assert_equal (9 * 60) + 30, Game.new(start_time: '9:30').start_time_sort_key
    assert_equal (9 * 60) + 30, Game.new(start_time: '09:30').start_time_sort_key
    assert_equal 14 * 60, Game.new(start_time: '14:00').start_time_sort_key
  end

  test 'ohne lesbare Zeit ans Ende' do
    [nil, '', 'TBD'].each do |value|
      assert_equal 24 * 60, Game.new(start_time: value).start_time_sort_key, value.inspect
    end
  end
end
