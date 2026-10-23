# Link zum Kalibrieren und Auswählen der Highlights eines Tablet-Spiels
# (fe#560), verschickt von TabletHighlightLinks, sobald die Aufzeichnung fertig
# ist.
#
# Bewusst `mail` statt `templated_mail`, wie TabletFeedbackMailer: Der Link ist
# der ganze Inhalt, eine gepflegte Vorlage ohne ihn liesse die Mail nutzlos
# werden.
class TabletHighlightMailer < ApplicationMailer
  def calibration_link(game, recipient, token, expires_at)
    @game = game
    @url = "#{FrontendUrl.base}/highlights/bearbeiten?token=#{CGI.escape(token)}"
    @expires_at = expires_at

    mail(
      to: recipient,
      subject: "Highlights bearbeiten – Spiel #{game.game_number} #{game.home_team_name} – #{game.guest_team_name}"
    )
  end
end
