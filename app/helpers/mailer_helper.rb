# Stellt den Mailer-Views die Frontend-Basis-URL bereit, damit E-Mail-Templates
# keine Hosts hartcodieren (sonst zeigen Staging-Mails auf das Produktivsystem).
module MailerHelper
  def frontend_base_url
    FrontendUrl.base
  end

  def frontend_host
    FrontendUrl.host
  end
end
