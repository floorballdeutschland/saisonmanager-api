require File.expand_path('../../config/environment', __FILE__)
require 'rails/test_help'
require 'minitest/mock'
require 'committee/rails/test/methods'

class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end

# Schema-Validierung der API-Responses gegen docs/openapi/openapi.yml.
# In Integration-Tests via `assert_schema_conform(status)` nach dem Request
# aufrufen — die komplette JSON-Response wird gegen das Schema des
# dokumentierten Endpoints geprüft.
class ActionDispatch::IntegrationTest
  include Committee::Rails::Test::Methods

  def committee_options
    @committee_options ||= {
      schema_path: Rails.root.join('docs', 'openapi', 'openapi.yml').to_s,
      prefix: '/api/v2',
      strict: false,
      strict_reference_validation: true,
      validate_success_only: false,
      parse_response_by_content_type: true
    }
  end
end
