require 'simplecov'
SimpleCov.start 'rails' do
  add_filter '/test/'
  add_filter '/config/'
  add_filter '/db/'
end

require File.expand_path('../../config/environment', __FILE__)
require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'committee/rails/test/methods'

class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # FactoryBot: create / build / attributes_for direkt in jedem Test verfügbar.
  # Phase 1 stellt Factories für Setting, GameOperation, Club, Arena, League,
  # Team, Player, User bereit (siehe test/README.md).
  include FactoryBot::Syntax::Methods

  # Deaktivierung im Zustand VOR api#472: zusaetzlich zur Kennzeichnung sind alle
  # gueltigen Vereinszugehoerigkeiten geschlossen und alle laufenden Lizenzen auf
  # DELETED gesetzt.
  #
  # Auf Produktion liegen tausende Profile in genau diesem Zustand. Tests, die die
  # Ruecknahme dieser Nebenwirkungen pruefen (`Player#reactivate!`,
  # `rake players:reset_deactivation_side_effects`, `Club#players`), muessen ihn
  # herstellen — `deactivate!` selbst erzeugt ihn nicht mehr.
  def legacy_deactivate!(player, user_id, reason: nil)
    player._void_memberships_and_licenses!(user_id, reason: reason || 'Deaktiviert')
    player.deactivate!(user_id, reason: reason)
    player
  end
end

# Rack::Attack zählt seine Throttles in einem Cache-Store, den es sich beim
# allerersten Zugriff auf `Rack::Attack.cache` einmalig aus `Rails.cache` holt
# und danach dauerhaft festhält (siehe Rack::Attack::Cache#initialize).
#
# Im Test-Env ist `Rails.cache` ein :null_store, in dem nichts liegen bleibt, es
# würde also nie gezählt. Einzelne Tests tauschten `Rails.cache` deshalb für ihre
# Dauer gegen einen echten Store. Fiel der erste gedrosselte Request des
# Prozesses zufällig in so einen Block, hielt Rack::Attack diesen Store für den
# Rest des Laufs fest und zählte darin weiter: Ab dem elften Request auf die
# Mail-Endpunkte antwortete dann jeder Test mit 429, abhängig von der
# Testreihenfolge und damit vom Seed (#282).
#
# Deshalb hier ein eigener Store, gesetzt bevor der erste Test läuft. Er hängt
# nicht an `Rails.cache` und wird nicht mehr ausgetauscht; jeder Test startet
# dank des `setup` unten bei null.
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

# Schema-Validierung der API-Responses gegen docs/openapi/openapi.yml.
# In Integration-Tests via `assert_schema_conform(status)` nach dem Request
# aufrufen — die komplette JSON-Response wird gegen das Schema des
# dokumentierten Endpoints geprüft.
class ActionDispatch::IntegrationTest
  include Committee::Rails::Test::Methods

  # Throttle-Zähler nicht über Testgrenzen hinweg schleppen.
  setup { Rack::Attack.cache.store.clear }

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
