class EmailLogObserver
  def self.delivered_email(message)
    return if Rails.env.test?

    EmailLog.create!(
      recipient: Array(message.to).join(', '),
      cc: Array(message.cc).presence&.join(', '),
      subject: message.subject.to_s,
      mailer_action: [
        message['X-Mailer-Class']&.value,
        message['X-Mailer-Action']&.value
      ].compact.join('#').presence,
      sent_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("EmailLogObserver failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e)
  end
end
