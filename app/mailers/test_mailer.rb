class TestMailer < ApplicationMailer
  def send_test(recipient)
    @recipient = recipient
    mail(to: recipient, subject: "Test E-Mail #{Time.now}")
  end
end
