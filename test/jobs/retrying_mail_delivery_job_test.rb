require 'test_helper'

# Ein vorübergehender SMTP-Fehler darf die Mail nicht kosten. Am 24.08.2026
# hat er vier Lizenzmails eines Kursimports gekostet: Microsoft 365 antwortete
# mit `432 4.3.2 Concurrent connections limit exceeded`, der
# Default-Zustellauftrag kennt keinen Retry, und der :async-Adapter hält
# nichts fest.
class RetryingMailDeliveryJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Zustellweg, der beim ersten Versuch das Verbindungslimit meldet und danach
  # durchlässt. `initialize(settings)` ist alles, was ActionMailer von einer
  # Zustellmethode verlangt (siehe Mail::Message#delivery_method).
  class FlakySmtpDelivery
    class << self
      attr_accessor :attempts, :delivered

      def reset!
        self.attempts = 0
        self.delivered = []
      end
    end

    def initialize(settings = {})
      @settings = settings
    end

    def deliver!(mail)
      self.class.attempts += 1
      if self.class.attempts == 1
        raise Net::SMTPServerBusy.new(nil, message: '432 4.3.2 Concurrent connections limit exceeded')
      end

      self.class.delivered << mail
    end
  end

  setup do
    FlakySmtpDelivery.reset!
    ActionMailer::Base.add_delivery_method(:flaky_smtp, FlakySmtpDelivery)
    @original_delivery_method = ActionMailer::Base.delivery_method
  end

  teardown do
    ActionMailer::Base.delivery_method = @original_delivery_method
  end

  test 'deliver_later benutzt den Zustellauftrag mit Retry' do
    assert_equal RetryingMailDeliveryJob, ActionMailer::Base.delivery_job

    assert_enqueued_with(job: RetryingMailDeliveryJob) do
      TestMailer.send_test('schiri@example.org').deliver_later
    end
  end

  test 'ein 432 vom Mailserver wird wiederholt und die Mail kommt raus' do
    ActionMailer::Base.delivery_method = :flaky_smtp

    perform_enqueued_jobs do
      TestMailer.send_test('schiri@example.org').deliver_later
    end

    assert_equal 2, FlakySmtpDelivery.attempts, 'der zweite Versuch fehlt'
    assert_equal 1, FlakySmtpDelivery.delivered.size, 'die Mail ist nicht zugestellt worden'
    assert_equal ['schiri@example.org'], FlakySmtpDelivery.delivered.first.to
  end

  test 'transiente Fehler sind hinterlegt, permanente nicht' do
    handled = RetryingMailDeliveryJob.rescue_handlers.map(&:first)

    assert_includes handled, 'Net::SMTPServerBusy'
    assert_includes handled, 'Errno::ECONNRESET'
    assert_not_includes handled, 'Net::SMTPFatalError'
    assert_not_includes handled, 'Net::SMTPSyntaxError'
  end
end
