require 'test_helper'

# Der Mutex aus config/initializers/smtp_serialized_delivery.rb hält die Zahl
# der gleichzeitig offenen SMTP-Verbindungen bei eins. Ohne ihn schickt der
# Threadpool des :async-Adapters eine ganze Tranche parallel los und läuft bei
# Microsoft 365 in `432 4.3.2 Concurrent connections limit exceeded`.
class SerializedSmtpDeliveryTest < ActiveSupport::TestCase
  test 'Mail::SMTP ist der Serialisierung vorgeschaltet' do
    ancestors = Mail::SMTP.ancestors

    assert_includes ancestors, SerializedSmtpDelivery
    assert ancestors.index(SerializedSmtpDelivery) < ancestors.index(Mail::SMTP),
           'SerializedSmtpDelivery muss vor Mail::SMTP stehen, sonst greift deliver! nicht'
  end

  test 'zwei parallele Zustellungen überlappen nicht' do
    probe = Class.new do
      prepend SerializedSmtpDelivery

      attr_reader :max_parallel

      def initialize
        @parallel = 0
        @max_parallel = 0
        @counter_lock = Mutex.new
      end

      def deliver!(_mail)
        @counter_lock.synchronize do
          @parallel += 1
          @max_parallel = [@max_parallel, @parallel].max
        end
        sleep 0.05
        @counter_lock.synchronize { @parallel -= 1 }
      end
    end.new

    4.times.map { Thread.new { probe.deliver!(nil) } }.each(&:join)

    assert_equal 1, probe.max_parallel
  end
end
