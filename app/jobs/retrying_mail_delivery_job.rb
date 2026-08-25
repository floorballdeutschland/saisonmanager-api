require 'net/smtp'

# Zustellauftrag für `deliver_later` (config.action_mailer.delivery_job).
#
# Zwei Aufgaben, beide aus demselben Vorfall: Ein Kursimport hat am 24.08.2026
# 22 Lizenzmails in vier Sekunden eingereiht, Microsoft 365 wies vier davon mit
# `432 4.3.2 Concurrent connections limit exceeded` ab, und die waren damit weg
# (SAISONMANAGER-3T).
#
# 1. Eigener Threadpool mit genau einem Thread, siehe unten. Damit steht immer
#    nur eine SMTP-Verbindung aus dem Hintergrund offen.
# 2. Wiederholung, wenn der Mailserver trotzdem vorübergehend abweist.
class RetryingMailDeliveryJob < ActionMailer::MailDeliveryJob
  # Der Default-Threadpool des :async-Adapters hat `Concurrent.processor_count`
  # Threads und arbeitet eine Tranche entsprechend parallel ab, genau das hat
  # das Verbindungslimit gerissen. Mailzustellung bekommt deshalb ihren eigenen
  # Pool mit einem einzigen Thread.
  #
  # Ein prozessweiter Mutex im Zustellweg (Mail::SMTP#deliver!) wäre der
  # kürzere Weg gewesen, aber der falsche: Er hätte auch die synchronen
  # Zustellungen aus dem Request getroffen. `User#send_reset_information` und
  # `Admin::EmailLogsController#create` liefern mit `deliver_now`, ein
  # „Passwort vergessen" hätte also mitten in einer Tranche hinter deren
  # restlichen Mails gewartet, bei fünf Puma-Threads und zehn erlaubten
  # Versuchen pro Stunde und IP eine sehr wirksame Bremse. Der eigene Pool
  # hält die Serialisierung dort, wo die Tranchen entstehen, und lässt den
  # Request in Ruhe.
  #
  # Nebeneffekt: Andere Jobs (ActiveStorage-Varianten, Analyse) behalten den
  # gemeinsamen Pool für sich, statt hinter einer Mailtranche zu warten.
  def self.dedicated_async_adapter
    ActiveJob::QueueAdapters::AsyncAdapter.new(min_threads: 0, max_threads: 1, idletime: 60)
  end

  # Nur, wenn dieser Prozess überhaupt asynchron zustellt: Im Test bleibt der
  # :test-Adapter zuständig, sonst liefen alle Mailtests gegen einen echten
  # Threadpool. Ein späteres echtes Job-Backend (Sidekiq und Verwandte) bringt
  # seine eigene Begrenzung mit und wird hier ebenfalls nicht überschrieben.
  if ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)
    self.queue_adapter = dedicated_async_adapter
  end

  # Wiederholt werden Fehler, die vor der Annahme der Nachricht auftreten:
  # eine Abweisung mit 4xx (Verbindungslimit, Ratelimit pro Minute), eine
  # Verbindung, die nicht zustande kommt, und eine, die in eine
  # Zeitüberschreitung läuft.
  #
  # Net::SMTPAuthenticationError steht bewusst dabei, obwohl der Name nach
  # einem Konfigurationsfehler klingt: Net::SMTP::Authenticator#finish wirft
  # sie bei JEDER Antwort ungleich Erfolg auf den letzten AUTH-Schritt, ein
  # 432 in dieser Phase erscheint also unter diesem Namen. Ein echt falsches
  # Passwort kostet dadurch fünf Versuche pro Mail statt einem; gemeldet wird
  # es am Ende trotzdem.
  #
  # Nicht dabei, obwohl vorübergehend: EOFError, Errno::ECONNRESET und
  # Errno::EPIPE. Net::SMTP#do_finish schickt das QUIT ohne rescue, ein Abriss
  # an dieser Stelle fliegt also aus `deliver!` heraus, nachdem der Server die
  # Nachricht mit 250 längst angenommen hat. Diese drei zu wiederholen heißt
  # im Regelfall, dieselbe Mail ein zweites Mal zu schicken.
  #
  # Ebenfalls nicht dabei: dauerhafte Fehler (Net::SMTPFatalError,
  # Net::SMTPSyntaxError bei einer unbrauchbaren Adresse). Die würde jeder
  # weitere Versuch gleich wieder abweisen.
  #
  # Nicht zu verwechseln mit `User::MAIL_TRANSPORT_ERRORS`: Das ist eine
  # Fangliste für den synchronen Versand („der Request darf nicht abbrechen")
  # und deshalb bewusst weiter gefasst als diese Wiederholliste.
  #
  # Die Abstände bleiben kurz und flach (5, 10, 15, 20 Sekunden). Ein
  # Verbindungslimit ist nach Sekunden vorbei, und die Warteschlange liegt im
  # Arbeitsspeicher: Jede Minute, die ein Versuch später liegt, ist eine
  # Wette darauf, dass der Prozess bis dahin lebt. `:polynomially_longer`
  # hätte den letzten Versuch rund sechs Minuten nach hinten geschoben, ein
  # Deploy in diesem Fenster hätte die Mail ohne jede Spur verschluckt.
  #
  # Nach dem letzten Versuch wirft `retry_on` den Fehler weiter, der Fall
  # landet also in Sentry.
  retry_on Net::SMTPServerBusy,
           Net::SMTPAuthenticationError,
           Net::OpenTimeout,
           Net::ReadTimeout,
           Net::WriteTimeout,
           SocketError,
           Errno::ECONNREFUSED,
           Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError,
           wait: ->(executions) { (executions * 5).seconds },
           attempts: 5
end
