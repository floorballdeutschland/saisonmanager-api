Sentry.init do |config|
  config.dsn = 'https://85b4823c49024668be39942d31c3fc21@o1082542.ingest.sentry.io/6091175'
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Set tracesSampleRate to 1.0 to capture 100%
  # of transactions for performance monitoring.
  # We recommend adjusting this value in production
  config.traces_sample_rate = 0.5
  # or
  config.traces_sampler = lambda do |context|
    true
  end
end
