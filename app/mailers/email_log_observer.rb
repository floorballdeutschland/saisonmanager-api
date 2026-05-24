class EmailLogObserver
  def self.delivered_email(message)
    return if Rails.env.test?

    EmailLog.create!(
      recipient: Array(message.to).join(', '),
      cc: Array(message.cc).presence&.join(', '),
      subject: message.subject.to_s,
      mailer_action: [
        message['mailer-class']&.value,
        message['mailer-action']&.value
      ].compact.join('#').presence,
      sent_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error "EmailLogObserver: #{e.message}"
  end
end
