class RefereeMailer < ApplicationMailer
  REPLY_TO = 'sr-ansetzungen@floorball.de'

  def license_notification(referee)
    @referee = referee

    templated_mail(
      to: referee.email,
      subject: "Schiedsrichterlizenz aktualisiert – #{referee.vorname} #{referee.nachname}",
      default_reply_to: 'rsk@floorball.de',
      placeholders: { referee_name: "#{referee.vorname} #{referee.nachname}" }
    )
  end

  def wallet_pass_issued(referee, pass_url)
    @referee = referee
    @pass_url = pass_url

    templated_mail(
      to: referee.email,
      subject: "Dein Schiedsrichterausweis | #{referee.vorname} #{referee.nachname}",
      default_reply_to: 'rsk@floorball.de',
      placeholders: { referee_name: "#{referee.vorname} #{referee.nachname}" }
    )
  end

  def tentative_assignment_notification(referee, date)
    @referee = referee
    @date = date

    templated_mail(
      to: referee.email,
      subject: "Vorläufige Ansetzung – #{I18n.l(date, format: :long)}",
      default_reply_to: REPLY_TO,
      placeholders: { date: I18n.l(date, format: :long) }
    )
  end

  def published_assignment_notification(referee, game, partner, club_contact_email, coach: nil, license_list_url: nil, license_expires_at: nil)
    @referee = referee
    @game = game
    @partner = partner
    @coach = coach
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at

    templated_mail(
      to: referee.email,
      subject: "Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}",
      default_reply_to: REPLY_TO,
      placeholders: {
        game_date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        coach_name: coach ? "#{coach.vorname} #{coach.nachname}" : ''
      }
    )
  end

  # Ansetzungs-Mail an den Schiedsrichtercoach: gleiche Spieltag-Details und
  # Lizenzlisten wie für die Schiris, plus die Namen der angesetzten Schiris.
  def published_coach_notification(coach, game, official_names, club_contact_email, license_list_url: nil, license_expires_at: nil)
    @coach = coach
    @game = game
    @official_names = official_names
    @club_contact_email = club_contact_email
    @license_list_url = license_list_url
    @license_expires_at = license_expires_at

    templated_mail(
      to: coach.email,
      subject: "Schiedsrichtercoach-Ansetzung – #{game.game_day.date} #{game.home_team&.name} vs. #{game.guest_team&.name}",
      default_reply_to: REPLY_TO,
      placeholders: {
        game_date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        officials: official_names.to_s
      }
    )
  end

  def incident_report_reminder(referee1, referee2, game, deadline)
    @referee1 = referee1
    @referee2 = referee2
    @game = game
    @deadline = deadline
    @upload_url = "https://saisonmanager.org/spielbericht/#{game.id}"

    templated_mail(
      to: [referee1.email, referee2.email].compact,
      subject: "Spielnummer #{game.game_number} | 24h Zeit für Berichtsformular",
      default_reply_to: sbk_reply_to(game),
      placeholders: { game_number: game.game_number }
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

    templated_mail(
      to: vsk_email,
      subject: "Berichtsformular eingereicht – Spielnummer #{game.game_number}",
      default_reply_to: sbk_reply_to(game),
      placeholders: { game_number: game.game_number }
    )
  end

  private

  # SBK-Adresse des Spielbetriebs (Landesverband des game_operation);
  # Fallback auf die Ansetzungs-Adresse, falls keine SBK-Adresse hinterlegt ist.
  def sbk_reply_to(game)
    game.league.game_operation.state_association&.sbk_email.presence || REPLY_TO
  end
end
