class RefereeMailer < ApplicationMailer
  REPLY_TO = 'sr-ansetzungen@floorball.de'

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

  def tentative_assignment_notification(referee, date)
    @referee = referee
    @date = date

    mail(
      to: referee.email,
      reply_to: REPLY_TO,
      subject: "Vorläufige Ansetzung – #{I18n.l(date, format: :long)}"
    )
  end

  def published_assignment_notification(referee, game, partner, club_contact_email, license_list_url: nil, license_expires_at: nil)
    @referee = referee
    @game = game
    @partner = partner
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at

    mail(
      to: referee.email,
      reply_to: REPLY_TO,
      subject: "Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}"
    )
  end

  def incident_report_reminder(referee1, referee2, game, deadline)
    @referee1 = referee1
    @referee2 = referee2
    @game = game
    @deadline = deadline

    mail(
      to: [referee1.email, referee2.email].compact,
      reply_to: REPLY_TO,
      subject: "Spielnummer #{game.game_number} | 24h Zeit für Berichtsformular"
    )
  end
end
