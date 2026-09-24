require 'test_helper'
require 'net/smtp'

# BlockingMailDeliveryAdapter ist der Zustellweg fuer Mails aus
# rake transfers:execute_scheduled. Geprueft an eigenen Jobklassen, damit
# Wiederholung und Fehler ohne echten Mailserver reproduzierbar sind.
class BlockingMailDeliveryAdapterTest < ActiveSupport::TestCase
  class FlakyJob < ActiveJob::Base
    retry_on Net::SMTPServerBusy, wait: 5.seconds, attempts: 3
    cattr_accessor :calls, default: 0

    def perform
      self.class.calls += 1
      raise Net::SMTPServerBusy, '432 Concurrent connections limit exceeded' if self.class.calls == 1
    end
  end

  class BrokenJob < ActiveJob::Base
    def perform
      raise Net::SMTPFatalError, '554 SendAsDenied'
    end
  end

  class OkJob < ActiveJob::Base
    cattr_accessor :calls, default: 0

    def perform
      self.class.calls += 1
    end
  end

  setup do
    FlakyJob.calls = 0
    OkJob.calls = 0
    @pauses = []
    pauses = @pauses
    @adapter = BlockingMailDeliveryAdapter.new
    @adapter.define_singleton_method(:pause) { |seconds| pauses << seconds }
  end

  def with_adapter(*job_classes)
    previous = job_classes.map(&:queue_adapter)
    job_classes.each { |k| k.queue_adapter = @adapter }
    yield
  ensure
    job_classes.zip(previous).each { |k, p| k.queue_adapter = p }
  end

  # :inline wirft bei `retry_on ... wait:` NotImplementedError, und das ist
  # kein StandardError -- ein einziges 432 haette den Lauf beendet.
  test 'wiederholt eine voruebergehende Abweisung nach der Wartezeit' do
    with_adapter(FlakyJob) { FlakyJob.perform_later }

    assert_equal 2, FlakyJob.calls
    assert_equal 1, @pauses.size
    assert_in_delta 5, @pauses.first, 1
    assert_empty @adapter.failures
  end

  test 'ein endgueltiger Fehler bleibt bei dieser Mail, die naechste geht raus' do
    with_adapter(BrokenJob, OkJob) do
      BrokenJob.perform_later
      OkJob.perform_later
    end

    assert_equal 1, OkJob.calls
    assert_equal [Net::SMTPFatalError], @adapter.failures.map(&:class)
  end

  test 'around setzt den Adapter nur fuer die Dauer des Blocks' do
    before = OkJob.queue_adapter
    seen = nil
    BlockingMailDeliveryAdapter.around(OkJob) { seen = OkJob.queue_adapter }

    assert_kind_of BlockingMailDeliveryAdapter, seen
    assert_same before, OkJob.queue_adapter
  end
end
