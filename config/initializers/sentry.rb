Sentry.init do |config|
  # DSN kommt aus der Umgebung (SENTRY_DSN), damit kein Projekt-Token im öffentlichen Repo liegt.
  # Ist die Variable nicht gesetzt (z. B. lokale Entwicklung), bleibt Sentry inaktiv.
  config.dsn = ENV.fetch('SENTRY_DSN', nil)
  config.breadcrumbs_logger = %i[active_support_logger http_logger]
  config.enabled_environments = %w[production staging]

  # Set tracesSampleRate to 1.0 to capture 100%
  # of transactions for performance monitoring.
  # We recommend adjusting this value in production
  config.traces_sample_rate = 0.1
  # or
  config.traces_sampler = lambda do |_context|
    true
  end
end
