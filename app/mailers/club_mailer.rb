class ClubMailer < ApplicationMailer
  REPLY_TO = 'system@saisonmanager.de'

  def game_day_scan_reminder(club, game_day)
    @club = club
    @game_day = game_day
    @games = game_day.games.order(:start_time)
    @frontend_base_url = FrontendUrl.base

    # I18n.l auf game_day.date (Textspalte) warf hier ArgumentError, bevor die
    # Vorlage überhaupt gerendert wurde – die Mail war nie versendbar.
    date_label = MailerHelper.format_game_day_date(game_day.date)

    templated_mail(
      to: club.contact_email,
      subject: "Spielbericht-Scans einreichen – Spieltag #{date_label}",
      default_reply_to: REPLY_TO,
      placeholders: { game_day_date: date_label }
    )
  end
end
