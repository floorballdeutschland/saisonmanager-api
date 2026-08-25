require 'net/smtp'

# Zustellauftrag für `deliver_later` (config.action_mailer.delivery_job).
#
# Der Default ActionMailer::MailDeliveryJob kennt keinen Retry: Wirft der
# Mailserver einen vorübergehenden Fehler, ist die Mail weg, beim
# :async-Adapter ohne jede Spur außer dem Sentry-Eintrag. Genau so sind am
# 24.08.2026 vier Lizenzmails eines Kursimports verschwunden
# (`432 4.3.2 Concurrent connections limit exceeded`, SAISONMANAGER-3T).
#
# Die aufgeführten Fehler sind alle vorübergehend: ein 4xx vom Server, eine
# abgerissene oder nicht zustande gekommene Verbindung. Permanente Fehler
# (Net::SMTPFatalError, Net::SMTPSyntaxError bei einer unbrauchbaren Adresse)
# stehen bewusst nicht dabei, die würde jeder weitere Versuch gleich wieder
# abweisen.
#
# Reißt die Verbindung erst nach der Übergabe der Nachricht ab, kann die
# Wiederholung dieselbe Mail ein zweites Mal zustellen. Das ist der bewusst
# gewählte Preis: Eine Mail doppelt zu bekommen ist harmlos, eine
# Lizenzmitteilung nie zu bekommen nicht.
#
# Nach dem letzten Versuch wirft `retry_on` den Fehler weiter, der Fall landet
# also nach wie vor in Sentry und wird nicht stillschweigend verschluckt.
class RetryingMailDeliveryJob < ActionMailer::MailDeliveryJob
  retry_on Net::SMTPServerBusy,
           Net::OpenTimeout,
           Net::ReadTimeout,
           Errno::ECONNRESET,
           Errno::EPIPE,
           EOFError,
           wait: :polynomially_longer,
           attempts: 5
end
