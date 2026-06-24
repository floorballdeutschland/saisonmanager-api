class RefereeFeedbackMailer < ApplicationMailer
  FEEDBACK_URL = 'https://saisonmanager.org/verein/schiri-feedback'

  # Info an einen Teammanager, dass für ein gespieltes Spiel seiner Mannschaft das
  # Schiri-Feedback-Formular ausfüllbar ist (Fenster öffnet 24 h nach Anpfiff).
  def form_available(user, game, team)
    @user = user
    @game = game
    @team = team
    opponent = team.id == game.home_team_id ? game.guest_team : game.home_team
    @opponent_name = opponent&.name
    @league_name = game.league&.name
    @game_date = game.game_day&.date
    @feedback_url = FEEDBACK_URL

    templated_mail(
      to: user.email,
      subject: "Schiri-Feedback möglich – #{@team.name}",
      placeholders: {
        team_name: @team.name,
        opponent_name: @opponent_name.to_s,
        league_name: @league_name.to_s,
        link: FEEDBACK_URL
      }
    )
  end
end
