# Rückmeldung zur Beta des Tabletmodus (fe#560). Freitext aus der Erfassung,
# geht an das Postfach der Administration. Reply-To ist die schreibende Person,
# damit eine Rückfrage direkt aus dem Postfach möglich ist.
#
# Bewusst `mail` statt `templated_mail` und kein Eintrag im EmailTemplateCatalog:
# Eine gepflegte Vorlage ersetzte den Body ganz und ginge VOR dem Reply-To der
# schreibenden Person. Ein gepflegter Text ohne Freitext oder eine gepflegte
# Antwortadresse liesse die Rückmeldung still verschwinden bzw. Antworten ins
# falsche Postfach laufen, und gespeichert wird sie nirgends.
class TabletFeedbackMailer < ApplicationMailer
  # Über ENV überschreibbar, damit Staging nicht ins Produktiv-Postfach schreibt.
  NOTIFY_EMAIL = ENV.fetch('TABLET_FEEDBACK_NOTIFY_EMAIL', 'it@floorball.de').freeze

  def feedback(game, message, reply_to, sender, device)
    @game = game
    @message = message
    @reply_to = reply_to
    @sender = sender
    @device = device
    @shot_count = game.game_shots.shots.count
    @free_hit_count = game.game_shots.free_hits.count

    mail(
      to: NOTIFY_EMAIL,
      reply_to: reply_to.presence,
      subject: "Tabletmodus-Rückmeldung – Spiel #{game.game_number} #{game.home_team_name} – #{game.guest_team_name}"
    )
  end
end
