class RefereeFeedbackMailer < ApplicationMailer
  # Info an einen Teammanager, dass für ein Spiel seiner Mannschaft das
  # Schiri-Feedback-Formular ausfüllbar ist (Fenster öffnet mit dem Abschluss des
  # Spielberichts).
  def form_available(user, game, team)
    @user = user
    @game = game
    @team = team
    opponent = team.id == game.home_team_id ? game.guest_team : game.home_team
    @opponent_name = opponent&.name
    @league_name = game.league&.name
    @game_date = game.game_day&.date
    @feedback_url = "#{FrontendUrl.base}/verein/schiri-feedback"

    templated_mail(
      to: user.email,
      subject: "Schiri-Feedback möglich – #{@team.name}",
      placeholders: {
        team_name: @team.name,
        opponent_name: @opponent_name.to_s,
        league_name: @league_name.to_s,
        link: @feedback_url
      }
    )
  end

  # Einladung an eine Person ohne Benutzerkonto (Kapitän*in des Spiels oder der
  # von der Mannschaft hinterlegte Feedback-Kontakt), das Feedback über einen
  # Einmal-Link abzugeben. Der Rohtoken existiert nur hier, in der Datenbank
  # liegt lediglich sein Digest.
  #
  # Ein Opt-out über receive_info_mails gibt es hier nicht, weil kein
  # Benutzerkonto dahintersteht. Deshalb nennt die Mail, wer diese Adresse als
  # Feedback-Kontakt hinterlegt hat.
  def invitation(invitation, raw_token, source: nil)
    @invitation = invitation
    @game = invitation.game
    @team = invitation.team
    @source = source
    opponent = @team.id == @game.home_team_id ? @game.guest_team : @game.home_team
    @opponent_name = opponent&.name
    @league_name = @game.league&.name
    @game_date = @game.game_day&.date
    @feedback_url = "#{FrontendUrl.base}/schiri-feedback/abgeben/#{raw_token}"

    templated_mail(
      to: invitation.email,
      subject: "Schiri-Feedback abgeben – #{@team.name}",
      placeholders: {
        team_name: @team.name,
        opponent_name: @opponent_name.to_s,
        league_name: @league_name.to_s,
        link: @feedback_url
      }
    )
  end
end
