class RefereeMailer < ApplicationMailer
  def license_notification(referee, action:)
    @referee = referee
    @action = action # :created or :updated

    subject = if action == :created
                "Schiedsrichterausweis angelegt – #{referee.vorname} #{referee.nachname}"
              else
                "Schiedsrichterausweis aktualisiert – #{referee.vorname} #{referee.nachname}"
              end

    mail(to: referee.email, subject:)
  end
end
