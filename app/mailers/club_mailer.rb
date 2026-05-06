class ClubMailer < ApplicationMailer
  REPLY_TO = 'system@saisonmanager.org'

  def game_day_scan_reminder(club, game_day)
    @club = club
    @game_day = game_day
    @games = game_day.games.order(:start_time)
    @frontend_base_url = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'

    mail(
      to: club.contact_email,
      reply_to: REPLY_TO,
      subject: "Spielbericht-Scans einreichen – Spieltag #{I18n.l(game_day.date, format: :long)}"
    )
  end
end
