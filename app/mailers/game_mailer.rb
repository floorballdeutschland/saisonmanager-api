class GameMailer < ApplicationMailer
  # Geht nur noch an den Ausrichterverein (mit Token-Veto-Link). Schiedsrichter
  # bestätigen/beanstanden Spieltage stattdessen im Portal (s. checklist_referee_portal_notice).
  def checklist_confirmation(game, state_association, answers, hosting_club, veto_token = nil)
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

    bcc = !@all_ok ? state_association.sbk_email : nil

    templated_mail(
      to: hosting_club.contact_email,
      bcc: bcc.presence,
      subject: "Spielbericht Nr. #{game.game_number} eingereicht – #{game.home_team_name} vs. #{game.guest_team_name}",
      placeholders: {
        game_number: game.game_number,
        home_team: game.home_team_name,
        guest_team: game.guest_team_name
      }
    )
  end

  # Hinweis an die Schiedsrichter: Spieltag im Portal „Meine Spieltage" bestätigen
  # oder als nicht ordnungsgemäß melden (kein Token, Login erforderlich).
  def checklist_referee_portal_notice(game, referee_emails)
    @game = game
    @game_day = game.game_day
    frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
    @portal_url = "#{frontend_base}/schiedsrichter/spieltage"

    templated_mail(
      to: referee_emails,
      subject: "Spieltag bestätigen – #{game.home_team_name} vs. #{game.guest_team_name}",
      placeholders: {
        home_team: game.home_team_name,
        guest_team: game.guest_team_name
      }
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

    templated_mail(
      to: recipients,
      subject: "Einspruch eingereicht – Spielbericht Nr. #{game.game_number} – #{game.home_team_name} vs. #{game.guest_team_name}",
      placeholders: {
        game_number: game.game_number,
        home_team: game.home_team_name,
        guest_team: game.guest_team_name
      }
    )
  end
end
