require 'test_helper'

# Ein vorübergehender SMTP-Fehler darf die Mail nicht kosten. Am 24.08.2026
# hat er vier Lizenzmails eines Kursimports gekostet: Microsoft 365 antwortete
# mit `432 4.3.2 Concurrent connections limit exceeded`, der
# Default-Zustellauftrag kennt keinen Retry, und der :async-Adapter hält
# nichts fest.
class RetryingMailDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Zustellweg, der die hinterlegten Fehler der Reihe nach meldet und danach
  # durchlässt. `initialize(settings)` ist alles, was ActionMailer von einer
  # Zustellmethode verlangt (siehe Mail::Message#delivery_method).
  class ScriptedSmtpDelivery
    class << self
      attr_accessor :errors, :attempts, :delivered

      # `errors` ist die Liste der Fehler für die ersten Versuche; ist sie
      # abgearbeitet, wird zugestellt.
      def script(*errors)
        self.errors = errors
        self.attempts = 0
        self.delivered = []
      end
    end

    def initialize(settings = {})
      @settings = settings
    end

    def deliver!(mail)
      self.class.attempts += 1
      error = self.class.errors.shift
      raise error if error

      self.class.delivered << mail
    end
  end

  setup do
    ScriptedSmtpDelivery.script
    ActionMailer::Base.add_delivery_method(:scripted_smtp, ScriptedSmtpDelivery)
    @original_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :scripted_smtp
  end

  teardown do
    ActionMailer::Base.delivery_method = @original_delivery_method
  end

  def smtp_error(klass, text)
    klass.new(nil, message: text)
  end

  def deliver_one
    perform_enqueued_jobs do
      TestMailer.send_test('schiri@example.org').deliver_later
    end
  end

  test 'deliver_later benutzt den Zustellauftrag mit Retry' do
    assert_equal RetryingMailDeliveryJob, ActionMailer::Base.delivery_job

    assert_enqueued_with(job: RetryingMailDeliveryJob) do
      TestMailer.send_test('schiri@example.org').deliver_later
    end
  end

  test 'ein 432 vom Mailserver wird wiederholt und die Mail kommt raus' do
    ScriptedSmtpDelivery.script(
      smtp_error(Net::SMTPServerBusy, '432 4.3.2 Concurrent connections limit exceeded')
    )

    deliver_one

    assert_equal 2, ScriptedSmtpDelivery.attempts, 'der zweite Versuch fehlt'
    assert_equal 1, ScriptedSmtpDelivery.delivered.size, 'die Mail ist nicht zugestellt worden'
    assert_equal ['schiri@example.org'], ScriptedSmtpDelivery.delivered.first.to
  end

  # Net::SMTP::Authenticator#finish wirft bei jeder Antwort ungleich Erfolg
  # diesen Fehler, ein 432 auf dem letzten AUTH-Schritt erscheint also nicht
  # als Net::SMTPServerBusy. Ohne ihn in der Liste wäre dieselbe Abweisung in
  # einer anderen Phase weiterhin ein Mailverlust.
  test 'eine Abweisung beim Anmelden wird ebenfalls wiederholt' do
    ScriptedSmtpDelivery.script(
      smtp_error(Net::SMTPAuthenticationError, '432 4.3.2 STOREDRV; throttled')
    )

    deliver_one

    assert_equal 2, ScriptedSmtpDelivery.attempts
    assert_equal 1, ScriptedSmtpDelivery.delivered.size
  end

  test 'vier Abweisungen hintereinander werden durchgehalten' do
    ScriptedSmtpDelivery.script(
      *Array.new(4) { smtp_error(Net::SMTPServerBusy, '432 4.3.2 Concurrent connections limit exceeded') }
    )

    deliver_one

    assert_equal 5, ScriptedSmtpDelivery.attempts, 'fünf Versuche sind vorgesehen'
    assert_equal 1, ScriptedSmtpDelivery.delivered.size
  end

  # Ein dauerhafter Fehler taugt nicht für eine Wiederholung: Die Adresse
  # bleibt unbrauchbar, der Server weist gleich wieder ab. Er muss beim ersten
  # Versuch bleiben und weitergeworfen werden, damit er in Sentry landet.
  test 'ein dauerhafter Fehler wird nicht wiederholt' do
    ScriptedSmtpDelivery.script(
      smtp_error(Net::SMTPFatalError, '550 5.1.1 Recipient not found')
    )

    # Direkt ausgeführt statt über perform_enqueued_jobs: Der Testhelfer
    # verpackt einen durchgereichten Fehler in Minitest::UnexpectedError, und
    # das ist eine Minitest::Assertion, die assert_raises nicht fängt.
    assert_raises(Net::SMTPFatalError) do
      RetryingMailDeliveryJob.perform_now('TestMailer', 'send_test', 'deliver_now',
                                          args: ['schiri@example.org'])
    end

    assert_equal 1, ScriptedSmtpDelivery.attempts
    assert_empty ScriptedSmtpDelivery.delivered
    assert_no_enqueued_jobs
  end

  # Ein Abriss beim QUIT fliegt aus `deliver!` heraus, obwohl der Server die
  # Nachricht schon angenommen hat (Net::SMTP#do_finish schickt das QUIT ohne
  # rescue). Diese Fehler zu wiederholen hiesse, dieselbe Mail doppelt zu
  # schicken.
  test 'ein Verbindungsabriss wird nicht wiederholt' do
    handled = RetryingMailDeliveryJob.rescue_handlers.map(&:first)

    assert_not_includes handled, 'EOFError'
    assert_not_includes handled, 'Errno::ECONNRESET'
    assert_not_includes handled, 'Errno::EPIPE'
  end

  # Der Default-Pool des :async-Adapters hat so viele Threads wie Kerne und
  # schickt eine Tranche entsprechend parallel los, genau das hat das
  # Verbindungslimit gerissen.
  test 'Mailzustellung bekommt einen Threadpool mit genau einem Thread' do
    executor = RetryingMailDeliveryJob.dedicated_async_adapter
                                      .instance_variable_get(:@scheduler)
                                      .instance_variable_get(:@async_executor)

    assert_equal 1, executor.max_length
  end
end
