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
      # Route der Einspruchsseite im Frontend. Der frühere Pfad
      # /spielbericht/:id/einspruch existierte dort nie: die Seite fehlte
      # vollständig. Die öffentliche Verbandsroute (:association/:leagueId) nimmt
      # die ersten zwei Segmente, für das dritte („einspruch") hat sie keine
      # Kind-Route, und da es keine Wildcard-Route gibt, endete die Navigation
      # ohne Treffer auf einer leeren Seite statt auf einem Fehler.
      @veto_url = "#{FrontendUrl.base}/spieltagscheckliste/einspruch/#{game.id}?token=#{CGI.escape(veto_token)}"
    end

    bcc = !@all_ok ? state_association.effective_sbk_email : nil

    templated_mail(
      to: hosting_club.notification_emails,
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
    frontend_base = FrontendUrl.base
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

  # Hinweis an eine Gastmannschaft: Der Ausrichter hat den Spieltagsbericht
  # beantwortet, bestätigen oder beanstanden geht im Portal „Meine
  # Auswärtsspieltage" (Login, kein Token-Link wie beim Ausrichter).
  #
  # Die Mail führt ALLE Antworten des Ausrichters auf, nicht nur die verneinten.
  # Genau darum geht es hier: Der Ausrichter beurteilt seinen eigenen Spieltag,
  # und die Gastmannschaft ist die einzige Stelle, die einem falschen Ja
  # widersprechen kann. Ohne die Liste müsste sie dafür erst ins Portal.
  #
  # Der Betreff nennt den Spieltagsbericht ausdrücklich. Die Ausrichter-Mail heißt
  # „Spielbericht Nr. X eingereicht" und war im Protokoll der Ausgangsmails nicht
  # als Mail zum Spieltagsbericht zu erkennen – die Suche danach ging ins Leere, obwohl
  # die Mail verschickt worden war.
  def checklist_guest_team_notice(game, team, recipients, answers, deadline)
    @game = game
    @game_day = game.game_day
    @team = team
    @answers = answers
    @all_ok = answers.all? { |a| a['answer'] == true }
    @deadline = deadline
    @portal_url = "#{FrontendUrl.base}/verein/spieltage"

    templated_mail(
      to: recipients,
      subject: "Spieltagsbericht bestätigen – #{game.home_team_name} vs. #{game.guest_team_name}",
      placeholders: {
        game_number: game.game_number,
        home_team: game.home_team_name,
        guest_team: game.guest_team_name,
        team_name: team.name,
        deadline: MailerHelper.format_deadline(deadline)
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
      state_association.effective_sbk_email,
      *hosting_club&.notification_emails,
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
