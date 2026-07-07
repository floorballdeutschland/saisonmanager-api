class ClubMailer < ApplicationMailer
  REPLY_TO = 'system@saisonmanager.org'

  def game_day_scan_reminder(club, game_day)
    @club = club
    @game_day = game_day
    @games = game_day.games.order(:start_time)
    @frontend_base_url = FrontendUrl.base

    templated_mail(
      to: club.contact_email,
      subject: "Spielbericht-Scans einreichen – Spieltag #{I18n.l(game_day.date, format: :long)}",
      default_reply_to: REPLY_TO,
      placeholders: { game_day_date: I18n.l(game_day.date, format: :long) }
    )
  end
end
