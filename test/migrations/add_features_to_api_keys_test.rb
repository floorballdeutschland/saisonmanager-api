require 'test_helper'
require Rails.root.join('db/migrate/20261029100000_add_features_to_api_keys')

# Die eigenen Schlüssel ohne Anfragegrenze behalten die ausführliche
# Statistik, Zugänge aus dem Antrag (immer mit Grenze) verlieren sie.
class AddFeaturesToApiKeysTest < ActiveSupport::TestCase
  test 'nur Schlüssel ohne Anfragegrenze bekommen detailed_stats' do
    eigen = create(:api_key, rate_limit: nil)
    partner = create(:api_key, rate_limit: 60)

    ActiveRecord::Migration.suppress_messages do
      AddFeaturesToApiKeys.new.down
      AddFeaturesToApiKeys.new.up
    end
    ApiKey.reset_column_information

    assert_equal %w[detailed_stats], eigen.reload.features
    assert_equal [], partner.reload.features
  end
end
