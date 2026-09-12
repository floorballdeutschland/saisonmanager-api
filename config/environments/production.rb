require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.cache_classes = true

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in either ENV["RAILS_MASTER_KEY"]
  # or in config/master.key. This key is used to decrypt credentials (and other encrypted files).
  config.require_master_key = true

  # Disable serving static files from the `/public` folder by default since
  # Apache or NGINX already handles this.
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.action_controller.asset_host = 'http://assets.example.com'

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = 'X-Sendfile' # for Apache
  # config.action_dispatch.x_sendfile_header = 'X-Accel-Redirect' # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.routes_prefix = '/api/storage'

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = 'wss://example.com/cable'
  # config.action_cable.allowed_request_origins = [ 'http://example.com', /http:\/\/example.*/ ]

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Use the lowest log level to ensure availability of diagnostic information
  # when problems arise.
  config.log_level = :info

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Cache-Store. Mit REDIS_URL ein von allen Puma-Workern geteilter Redis,
  # ohne ihn der bisherige prozesslokale :memory_store.
  #
  # Warum ueberhaupt geteilt: Sobald Puma mehrere Worker startet
  # (WEB_CONCURRENCY, siehe config/puma.rb), raeumt ein Rails.cache.delete nur
  # den Cache des Prozesses, der die Anfrage zufaellig bearbeitet hat.
  # Game#flush_league_caches erreichte dann nur einen von vier Workern, und
  # die uebrigen lieferten bis zu fuenf Minuten alte Tabellen,
  # Torschuetzenlisten und Spielstaende aus -- mitten im Livebetrieb.
  #
  # Warum NICHT :file_store, obwohl alle Worker im selben Container laufen und
  # sich dessen Dateisystem teilen: Genau das lief hier schon einmal und wurde
  # am 18.07.2026 mit 17dc2cc8 entfernt ("fix(cache): Produktions-Cache auf
  # :memory_store (FileStore-Race behoben)", api#156).
  # ActiveSupport::Cache::FileStore raeumt in delete_empty_directories
  # Verzeichnisse weg, waehrend ein anderer Prozess hineinschreibt;
  # write_serialized_entry faengt nichts ab, der Fehler schlaegt bis zum
  # rescue_from durch. Betroffen war der API-Schluessel-Check in Rack::Attack
  # (ApiKey.meta_for, Fuenf-Minuten-TTL, bei jedem oeffentlichen Request
  # gelesen) -- ganze Public-Requests brachen mit 500 ab. Der Fehler steckt
  # unveraendert in activesupport 7.2.3.2, und mit vier Workern waere die
  # Nebenlaeufigkeit vervierfacht worden.
  #
  # Redis loest zugleich zwei Dinge, die ein file_store offen liesse: Es hat
  # eine Groessengrenze mit Verdraengung, waehrend ein Cache-Verzeichnis
  # unbegrenzt waechst -- versionierte Schluessel wie
  # games/<id>/full_hash/<updated_at> werden nie wieder gelesen und deshalb
  # nie abgeraeumt. Und es liegt ausserhalb des Containers, ueberdauert einen
  # Deploy also nicht als Datei im gemounteten Git-Checkout.
  #
  # Ohne REDIS_URL bleibt es beim :memory_store -- fuer einen einzelnen
  # Prozess die schnellste und sicherste Wahl. Die 128 MB liegen bewusst ueber
  # dem Default von 32 MB, damit die langlebigen Statistik-Caches
  # (Spieler-/Team-Stats, bis zu 1 Woche TTL) nicht durch Verdraengung
  # herausfallen und die Datenbanklast wieder hochtreiben.
  #
  # Dass Worker und prozesslokaler Cache nicht versehentlich zusammenkommen,
  # sichert config/initializers/shared_cache_required.rb ab.
  config.cache_store =
    if ENV['REDIS_URL'].present?
      [:redis_cache_store, {
        url: ENV['REDIS_URL'],
        # Ein haengender oder weggefallener Redis darf keine Anfrage aufhalten.
        # Bei einem Fehler verhaelt sich der Store wie "nicht im Cache", der
        # Block wird gerechnet: langsamer, aber nie ein 500er. Genau die
        # Eigenschaft, die dem file_store fehlte.
        connect_timeout: 1,
        read_timeout: 0.5,
        write_timeout: 0.5,
        reconnect_attempts: 1,
        error_handler: lambda { |method:, returning:, exception:|
          Sentry.capture_exception(
            exception,
            level: :warning,
            tags: { cache_method: method, cache_returning: returning }
          )
        }
      }]
    else
      [:memory_store, { size: 128.megabytes }]
    end

  # Use a real queuing backend for Active Job (and separate queues per environment).
  # config.active_job.queue_adapter     = :resque
  # config.active_job.queue_name_prefix = "saisonmanager_api_#{Rails.env}"

  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true

  config.action_mailer.delivery_method = :smtp
  # SMTP-Ziel ist per ENV überschreibbar, damit Staging Mails in einen lokalen
  # Catcher (Mailpit) statt an echte Empfänger schickt. Ohne SMTP_ADDRESS bleibt
  # das produktive Office-365-Setup unverändert.
  config.action_mailer.smtp_settings =
    if ENV['SMTP_ADDRESS'].present?
      # Catcher ohne Auth/TLS (z. B. Mailpit im Staging-Compose-Netz).
      {
        address: ENV['SMTP_ADDRESS'],
        port: (ENV['SMTP_PORT'].presence || 1025).to_i,
        domain: 'saisonmanager.dev',
        enable_starttls_auto: false,
        open_timeout: 10,
        read_timeout: 10
      }
    else
      {
        address: 'smtp.office365.com',
        port: 587,
        domain: 'saisonmanager.de',
        user_name: ENV['SMTP_USERNAME'],
        password: ENV['SMTP_PASSWORD'],
        authentication: :login,
        enable_starttls_auto: true,
        open_timeout: 10,
        read_timeout: 10
      }
    end

  # Der I18n-Fallback steht jetzt in config/application.rb und gilt damit für
  # alle Umgebungen. Hier wäre er inzwischen sogar schädlich: `fallbacks = true`
  # fällt auf die Default-Locale zurück, und die ist seit der deutschen
  # Datumsausgabe :de – die Kette endete also bei sich selbst statt bei :en.
  # Außerdem hätte diese Zeile die Einstellung aus application.rb überschrieben,
  # weil config/environments/* Vorrang hat.

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  # Use a different logger for distributed setups.
  # require 'syslog/logger'
  # config.logger = ActiveSupport::TaggedLogging.new(Syslog::Logger.new 'app-name')

  if ENV['RAILS_LOG_TO_STDOUT'].present?
    logger           = ActiveSupport::Logger.new(STDOUT)
    logger.formatter = config.log_formatter
    config.logger    = ActiveSupport::TaggedLogging.new(logger)
  end

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Inserts middleware to perform automatic connection switching.
  # The `database_selector` hash is used to pass options to the DatabaseSelector
  # middleware. The `delay` is used to determine how long to wait after a write
  # to send a subsequent read to the primary.
  #
  # The `database_resolver` class is used by the middleware to determine which
  # database is appropriate to use based on the time delay.
  #
  # The `database_resolver_context` class is used by the middleware to set
  # timestamps for the last write to the primary. The resolver uses the context
  # class timestamps to determine how long to wait before reading from the
  # replica.
  #
  # By default Rails will store a last write timestamp in the session. The
  # DatabaseSelector middleware is designed as such you can define your own
  # strategy for connection switching and pass that into the middleware through
  # these configuration options.
  # config.active_record.database_selector = { delay: 2.seconds }
  # config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
  # config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
end
