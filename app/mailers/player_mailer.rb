class PlayerMailer < ApplicationMailer
  def license_approved(player, team)
    @player = player
    @team = team
    @league = team.league
    season = Setting.current_season['name']
    subject = "Lizenz erteilt – #{team.name}"
    subject += " (#{@league.name})" if @league
    subject += " - #{season}"
    templated_mail(
      to: player.email,
      subject:,
      placeholders: { team_name: team.name, league_name: @league&.name, season: }
    )
  end

  def express_license_requested(player, team, league)
    @player = player
    @team = team
    @league = league
    sa = team.club&.state_association
    sbk_email = sa&.sbk_email
    return if sbk_email.blank?

    templated_mail(
      to: sbk_email,
      subject: "Expresslizenz beantragt: #{player.first_name} #{player.last_name} (#{team.name})",
      placeholders: {
        player_name: "#{player.first_name} #{player.last_name}",
        team_name: team.name
      }
    )
  end
end
