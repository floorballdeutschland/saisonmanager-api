class TestMailer < ApplicationMailer
  def test(text)
    @text = text
    mail(to: 'janhoffi@gmail.com', cc: 'j.hoffmann@floorball.de', subject: "Test E-Mail #{Time.now}")
  end

  def send_test(recipient)
    @recipient = recipient
    mail(to: recipient, subject: "Test E-Mail #{Time.now}")
  end
end
