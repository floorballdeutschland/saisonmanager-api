class GameMailer < ApplicationMailer
  def checklist_confirmation(game, state_association, answers, hosting_club, referee1, referee2, veto_token = nil)
    @game = game
    @state_association = state_association
    @answers = answers
    @hosting_club = hosting_club
    @all_ok = answers.all? { |a| a['answer'] == true }
    @failed_items = answers.select { |a| a['answer'] == false }

    if veto_token
      frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
      @veto_url = "#{frontend_base}/spielbericht/#{game.id}/einspruch?token=#{veto_token}"
    end

    recipients = [hosting_club.contact_email, referee1&.email, referee2&.email].compact.uniq
    bcc = !@all_ok ? state_association.sbk_email : nil

    mail(
      to: recipients,
      bcc: bcc.presence,
      subject: "Spielbericht Nr. #{game.game_number} eingereicht – #{game.home_team_name} vs. #{game.guest_team_name}"
    )
  end

  def checklist_veto_notification(game, state_association, veto_answers, hosting_club, referee1, referee2)
    @game = game
    @state_association = state_association
    @veto_answers = veto_answers
    @hosting_club = hosting_club
    @all_ok = veto_answers.all? { |a| a['answer'] == true }
    @failed_items = veto_answers.select { |a| a['answer'] == false }
    @original_answers = game.checklist_answers || []

    recipients = [
      state_association.sbk_email,
      hosting_club&.contact_email,
      referee1&.email,
      referee2&.email
    ].compact.uniq

    mail(
      to: recipients,
      subject: "Einspruch eingereicht – Spielbericht Nr. #{game.game_number} – #{game.home_team_name} vs. #{game.guest_team_name}"
    )
  end
end
