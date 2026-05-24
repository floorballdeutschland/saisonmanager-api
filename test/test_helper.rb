require File.expand_path('../../config/environment', __FILE__)
require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'

class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # FactoryBot: create / build / attributes_for direkt in jedem Test verfügbar.
  # Phase 1 stellt Factories für Setting, GameOperation, Club, Arena, League,
  # Team, Player, User bereit (siehe test/README.md).
  include FactoryBot::Syntax::Methods
end
