# Mails rund um den Antrag auf einen API-Zugang: Eingangsmeldung an die
# Administration sowie Entscheidung an den Antragsteller.
class ApiKeyApplicationMailer < ApplicationMailer
  # Postfach, das neue Anträge sichtet. Über ENV überschreibbar, damit Staging
  # nicht ins Produktiv-Postfach schreibt.
  NOTIFY_EMAIL = ENV.fetch('API_ACCESS_NOTIFY_EMAIL', 'it@floorball.de').freeze

  # Eingang eines neuen Antrags. Reply-To ist der Antragsteller, damit eine
  # Rückfrage direkt aus dem Postfach möglich ist.
  def submitted_notification(application)
    @application = application

    templated_mail(
      to: NOTIFY_EMAIL,
      default_reply_to: application.email,
      placeholders: {
        organisation: application.organisation,
        contact_name: application.contact_name
      }
    )
  end

  # Genehmigung mit dem Einmal-Link zum Abholen des Keys. Der Key selbst steht
  # bewusst nicht in der Mail.
  def approved(application, reveal_token)
    @application = application
    @reveal_url = "#{FrontendUrl.base}/api-zugang/schluessel?token=#{reveal_token}"
    @expires_at = application.reveal_token_expires_at

    templated_mail(
      to: application.email,
      placeholders: {
        organisation: application.organisation,
        link: @reveal_url
      }
    )
  end

  def rejected(application)
    @application = application

    templated_mail(
      to: application.email,
      placeholders: {
        organisation: application.organisation,
        decision_note: application.decision_note.to_s
      }
    )
  end
end
