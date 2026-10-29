require 'test_helper'

class ApiKeyTest < ActiveSupport::TestCase
  test 'features werden bereinigt: Leeres, Doppeltes und Symbole' do
    key = create(:api_key, features: ['detailed_stats', 'detailed_stats', '', nil, :league_shot_stats])

    assert key.valid?
    assert_equal %w[detailed_stats league_shot_stats], key.reload.features
    assert key.feature?(:league_shot_stats)
  end

  test 'unbekannte features machen den Schlüssel ungültig' do
    key = build(:api_key, features: %w[detailed_stats alles])

    assert_not key.valid?
    assert_includes key.errors[:features].join, 'alles'
  end

  test 'ohne Angabe keine Freigabe' do
    assert_equal [], create(:api_key).features
  end
end
