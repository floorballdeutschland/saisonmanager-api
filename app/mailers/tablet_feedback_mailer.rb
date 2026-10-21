# Rückmeldung zur Beta des Tabletmodus (fe#560). Freitext aus der Erfassung,
# geht an das Postfach der Administration. Reply-To ist die schreibende Person,
# damit eine Rückfrage direkt aus dem Postfach möglich ist.
class TabletFeedbackMailer < ApplicationMailer
  # Über ENV überschreibbar, damit Staging nicht ins Produktiv-Postfach schreibt.
  NOTIFY_EMAIL = ENV.fetch('TABLET_FEEDBACK_NOTIFY_EMAIL', 'it@floorball.de').freeze

  def feedback(game, message, reply_to, sender, device)
    @game = game
    @message = message
    @reply_to = reply_to
    @sender = sender
    @device = device
    @shot_count = game.game_shots.count

    templated_mail(
      to: NOTIFY_EMAIL,
      default_reply_to: reply_to.presence,
      placeholders: {
        game_number: game.game_number.to_s,
        home_team: game.home_team_name.to_s,
        guest_team: game.guest_team_name.to_s
      }
    )
  end
end
