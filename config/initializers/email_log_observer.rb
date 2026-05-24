Rails.application.config.to_prepare do
  Mail.register_observer(EmailLogObserver)
end
