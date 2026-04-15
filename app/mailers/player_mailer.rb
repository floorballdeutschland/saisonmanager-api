class PlayerMailer < ApplicationMailer
  def license_approved(player, team)
    @player = player
    @team = team
    mail(to: player.email, subject: "Lizenz erteilt – #{team.name}")
  end
end
