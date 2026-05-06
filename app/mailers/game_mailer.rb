class GameMailer < ApplicationMailer
  def checklist_confirmation(game, state_association, answers, hosting_club, referee1, referee2)
    @game = game
    @state_association = state_association
    @answers = answers
    @hosting_club = hosting_club
    @all_ok = answers.all? { |a| a['answer'] == true }
    @failed_items = answers.select { |a| a['answer'] == false }

    recipients = [hosting_club.contact_email, referee1&.email, referee2&.email].compact.uniq
    bcc = !@all_ok ? state_association.sbk_email : nil

    mail(
      to: recipients,
      bcc: bcc.presence,
      subject: "Spielbericht Nr. #{game.game_number} eingereicht – #{game.home_team_name} vs. #{game.guest_team_name}"
    )
  end
end
