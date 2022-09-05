class TestMailer < ApplicationMailer
  def test(text)
    @text = text
    mail(to: 'janhoffi@gmail.com', cc: 'j.hoffmann@floorball.de', subject: "Test E-Mail #{Time.now}")
  end
end
