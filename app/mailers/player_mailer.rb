class PlayerMailer < ApplicationMailer
  def license_approved(player, team)
    @player = player
    @team = team
    mail(to: player.email, subject: "Lizenz erteilt – #{team.name}")
  end

  def express_license_requested(player, team, league)
    @player = player
    @team = team
    @league = league
    sa = team.club&.state_association
    sbk_email = sa&.sbk_email
    return if sbk_email.blank?

    mail(
      to: sbk_email,
      subject: "Expresslizenz beantragt: #{player.first_name} #{player.last_name} (#{team.name})"
    )
  end
end
