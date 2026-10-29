require 'test_helper'
require Rails.root.join('db/migrate/20261029100000_add_features_to_api_keys')

# Die von Hand angelegten Schlüssel behalten die ausführliche Statistik,
# Zugänge aus dem Antrag verlieren sie, unabhängig von der Anfragegrenze.
class AddFeaturesToApiKeysTest < ActiveSupport::TestCase
  test 'nur von Hand angelegte Schlüssel bekommen detailed_stats' do
    create(:setting)
    eigen = create(:api_key, rate_limit: nil)
    eigen_mit_grenze = create(:api_key, rate_limit: 120)
    antrag = create(:api_key_application)
    antrag.approve!(create(:user, :admin).id)
    antrag.reveal_key!
    partner = antrag.reload.api_key
    partner.update!(rate_limit: nil)

    ActiveRecord::Migration.suppress_messages do
      AddFeaturesToApiKeys.new.down
      AddFeaturesToApiKeys.new.up
    end
    ApiKey.reset_column_information

    assert_equal %w[detailed_stats], eigen.reload.features
    assert_equal %w[detailed_stats], eigen_mit_grenze.reload.features
    assert_equal [], partner.reload.features, 'Antrag verliert die Statistik auch ohne Grenze'
  end
end
