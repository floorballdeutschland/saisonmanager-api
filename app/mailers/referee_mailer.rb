class RefereeMailer < ApplicationMailer
  REPLY_TO = 'sr-ansetzungen@floorball.de'

  def license_notification(referee)
    @referee = referee

    mail(
      to: referee.email,
      reply_to: 'rsk@floorball.de',
      subject: "Schiedsrichterlizenz aktualisiert – #{referee.vorname} #{referee.nachname}"
    )
  end

  def wallet_pass_issued(referee, pass_url)
    @referee = referee
    @pass_url = pass_url

    mail(
      to: referee.email,
      reply_to: 'rsk@floorball.de',
      subject: "Dein Schiedsrichterausweis | #{referee.vorname} #{referee.nachname}"
    )
  end

  def tentative_assignment_notification(referee, date)
    @referee = referee
    @date = date

    mail(
      to: referee.email,
      reply_to: REPLY_TO,
      subject: "Vorläufige Ansetzung – #{I18n.l(date, format: :long)}"
    )
  end

  def published_assignment_notification(referee, game, partner, club_contact_email, license_list_url: nil, license_expires_at: nil)
    @referee = referee
    @game = game
    @partner = partner
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at

    mail(
      to: referee.email,
      reply_to: REPLY_TO,
      subject: "Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}"
    )
  end

  def incident_report_reminder(referee1, referee2, game, deadline)
    @referee1 = referee1
    @referee2 = referee2
    @game = game
    @deadline = deadline
    @upload_url = "https://saisonmanager.org/spielbericht/#{game.id}"

    mail(
      to: [referee1.email, referee2.email].compact,
      reply_to: sbk_reply_to(game),
      subject: "Spielnummer #{game.game_number} | 24h Zeit für Berichtsformular"
    )
  end

  def referee_report_to_vsk(vsk_email, uploader, game, report, referee1, referee2, game_url: nil, checklist_answers: [])
    @uploader = uploader
    @game = game
    @referee1 = referee1
    @referee2 = referee2
    @game_url = game_url
    @checklist_answers = checklist_answers
    @checklist_all_ok = checklist_answers.all? { |a| a['answer'] == true }
    @checklist_failed_items = checklist_answers.select { |a| a['answer'] == false }

    if report.file.attached?
      blob = report.file.blob
      attachments[blob.filename.to_s] = {
        mime_type: blob.content_type,
        content: blob.download
      }
    end

    mail(
      to: vsk_email,
      reply_to: sbk_reply_to(game),
      subject: "Berichtsformular eingereicht – Spielnummer #{game.game_number}"
    )
  end

  private

  # SBK-Adresse des Spielbetriebs (Landesverband des game_operation);
  # Fallback auf die Ansetzungs-Adresse, falls keine SBK-Adresse hinterlegt ist.
  def sbk_reply_to(game)
    game.league.game_operation.state_association&.sbk_email.presence || REPLY_TO
  end
end
