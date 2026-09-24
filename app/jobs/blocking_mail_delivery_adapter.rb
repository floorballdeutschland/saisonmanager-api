# Queue-Adapter fuer Mails aus einem Cron-Rake (rake transfers:execute_scheduled).
#
# Im Rake-Prozess ist der :async-Pool von RetryingMailDeliveryJob keine Hilfe:
# Seine Threads sterben mit dem Prozess, eingereihte Mails gehen still verloren.
# Die Modellmethoden verschicken aber mit deliver_later, und ein Umbau aller
# Aufrufer auf deliver_now waere der groessere Eingriff. Dieser Adapter stellt
# deshalb jede Mail sofort und im aufrufenden Thread zu.
#
# Zwei Unterschiede zum eingebauten :inline, beide noetig:
#
# 1. `enqueue_at` wartet und stellt dann zu. RetryingMailDeliveryJob
#    wiederholt eine 4xx-Abweisung mit `wait:`, und :inline wirft dort
#    NotImplementedError. Das ist ein ScriptError und kein StandardError, ein
#    einziges „432 Concurrent connections limit exceeded" haette also den
#    ganzen Lauf beendet.
# 2. Ein endgueltiger Fehler bleibt bei dieser einen Mail. Er wird gemeldet
#    und in `failures` gesammelt, aber nicht geworfen: Sonst brechen mit der
#    ersten abgewiesenen Mail auch die an die uebrigen Empfaengerkreise ab.
#
# Gesetzt wird er am Zustelljob selbst, nicht an ActiveJob::Base:
# RetryingMailDeliveryJob traegt einen eigenen Adapter, der einen geerbten
# ueberdeckt.
class BlockingMailDeliveryAdapter < ActiveJob::QueueAdapters::InlineAdapter
  attr_reader :failures

  def initialize
    super
    @failures = []
  end

  # Fuer die Dauer des Blocks liefert `job_class` blockierend zu. Gibt den
  # Adapter zurueck, damit der Aufrufer `failures` auswerten kann.
  def self.around(job_class)
    adapter = new
    previous = job_class.queue_adapter
    job_class.queue_adapter = adapter
    yield adapter
    adapter
  ensure
    job_class.queue_adapter = previous
  end

  def enqueue(job)
    ActiveJob::Base.execute(job.serialize)
  rescue StandardError => e
    @failures << e
    Rails.error.report(e, handled: true, context: { job: job.class.name, arguments: job.arguments.first(2) })
  end

  def enqueue_at(job, timestamp)
    delay = timestamp - Time.now.to_f
    pause(delay) if delay.positive?
    enqueue(job)
  end

  private

  # Eigene Methode, damit Tests die Wartezeit ueberspringen koennen.
  def pause(seconds)
    sleep(seconds)
  end
end
