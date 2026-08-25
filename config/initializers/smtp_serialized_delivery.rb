require 'mail'

# Microsoft 365 erlaubt pro Postfach nur eine Handvoll gleichzeitiger
# SMTP-Verbindungen und antwortet darüber hinaus mit
# `432 4.3.2 Concurrent connections limit exceeded`.
#
# Der :async-Adapter von ActiveJob arbeitet die Mail-Jobs aber in einem
# Threadpool ab, also mehrere gleichzeitig. Ein Kursimport hat am 24.08.2026
# 22 Lizenzmails in vier Sekunden eingereiht; vier davon liefen in das Limit
# und waren verloren, weil der :async-Adapter nichts festhält und der
# Zustellauftrag den Fehler damals nicht wiederholt hat (SAISONMANAGER-3T).
#
# Mail::SMTP öffnet pro `deliver!` eine eigene Verbindung. Der Mutex sorgt
# dafür, dass davon immer nur eine offen steht: Aus eigener Kraft ist das
# Limit damit nicht mehr erreichbar. Nebenbei bleibt die Reihenfolge der Mails
# einer Tranche erhalten.
#
# Serialisiert wird bewusst hier und nicht über `max_threads: 1` am
# Job-Adapter: Der Threadpool arbeitet auch ActiveStorage-Jobs ab, die sich
# hinter einer Mailtranche nicht anstellen sollen.
#
# Kein Ersatz für den Retry im RetryingMailDeliveryJob: Ein 432 kann auch von
# außen kommen (Ratelimit auf Nachrichten pro Minute, weitere Absender auf
# demselben Postfach), und ein zweiter Prozess hätte seinen eigenen Mutex.
module SerializedSmtpDelivery
  MUTEX = Mutex.new

  def deliver!(mail)
    MUTEX.synchronize { super }
  end
end

# Direkt beim Booten und nicht in ActiveSupport.on_load(:action_mailer):
# ActionMailer::Base wird erst beim ersten Zugriff geladen, der Riegel hinge
# sonst daran, wann das passiert.
Mail::SMTP.prepend(SerializedSmtpDelivery)
