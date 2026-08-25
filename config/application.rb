require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SaisonmanagerApi
  class Application < Rails::Application
    # config.middleware.use ActionDispatch::Cookies
    # config.middleware.use ActionDispatch::Session::CookieStore, key: '_namespace_key'

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 5.1

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration can go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded after loading
    # the framework and any gems in your application.

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = false

    # ActiveStorage-Varianten (z. B. verkleinerte Vereins-/Team-Logos) über libvips
    # erzeugen. Bei load_defaults 5.1 wäre der Default sonst :mini_magick, dessen Gem
    # nicht installiert ist – die kleine Logo-Variante schlug dadurch fehl.
    config.active_storage.variant_processor = :vips

    # Datum und Uhrzeit deutsch ausgeben (config/locales/de.yml). Ohne das lief
    # I18n.l gegen die Default-Locale :en und schrieb „January 10, 2026" in
    # durchgehend deutsche E-Mails.
    config.i18n.default_locale = :de
    # Fallback auf :en für alles, was de.yml nicht abdeckt, vor allem die
    # Fehlermeldungen aus ActiveRecord/ActiveModel: dafür gibt es keine deutschen
    # Übersetzungen (kein rails-i18n-Gem), sie bleiben also wie bisher englisch.
    # Bisher stand der Fallback nur in config/environments/production.rb; ohne
    # ihn in Entwicklung und Test würden dieselben Meldungen dort zu
    # „translation missing".
    config.i18n.fallbacks = [:en]

    # Zustellauftrag mit Retry für transiente SMTP-Fehler (siehe
    # RetryingMailDeliveryJob). Der Default ActionMailer::MailDeliveryJob
    # verwirft die Mail beim ersten Fehlschlag.
    config.action_mailer.delivery_job = 'RetryingMailDeliveryJob'

    config.middleware.use Rack::Attack
  end
end
