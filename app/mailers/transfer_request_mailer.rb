class TransferRequestMailer < ApplicationMailer
  # Absichtlich ohne den Spieler als Empfaenger: der Text richtet sich an den
  # abgebenden Verein und verlinkt in die Verwaltung, wofuer Spieler keinen
  # Zugang haben. Der Spieler wird erst mit #player_confirmation_request
  # angeschrieben, also wenn er selbst zustimmen oder ablehnen kann.
  def new_request_to_former_club(transfer_request)
    @transfer_request = transfer_request
    recipients = transfer_request.former_club.notification_emails.compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Neue#{release?(transfer_request) ? ' Spielerfreigabe-Anfrage' : ' Transferanfrage'}: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: release?(transfer_request) ? 'Spielerfreigabe-Anfrage' : 'Transferanfrage',
        player_name: player_name(transfer_request)
      }
    )
  end

  # Empfaenger ist die Postfachkette des abgebenden Vereins (eigenes Postfach,
  # sonst das des Verbunds). BENANNT wird im Text dagegen der zustaendige
  # Verband (Club#responsible_state_association), denn genehmigen darf nur der.
  # Beides faellt nur auseinander, wenn ein Kind-LV ein eigenes Postfach
  # pflegt: Dann liest es die Mail, entscheiden tut weiterhin der Verbund.
  def pending_lv_notification(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.former_club.state_association&.effective_sbk_email
    return unless sbk_email.present?

    templated_mail(
      to: sbk_email,
      subject: "#{request_noun(transfer_request)} zur Genehmigung: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def clubs_informed_lv_pending(transfer_request)
    @transfer_request = transfer_request
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email]
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} liegt beim Landesverband: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def rejected_notification(transfer_request)
    @transfer_request = transfer_request
    recipients = transfer_request.requesting_club.notification_emails
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} abgelehnt: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def player_confirmation_request(transfer_request)
    @transfer_request = transfer_request
    recipient = transfer_request.player.email
    return unless recipient.present?

    subject_prefix = release?(transfer_request) ? 'Spielerfreigabe-Anfrage' : 'Transferanfrage'
    templated_mail(
      to: recipient,
      subject: "#{subject_prefix}: Deine Zustimmung wird benoetigt - #{player_name(transfer_request)}",
      placeholders: {
        request_noun: subject_prefix,
        player_name: player_name(transfer_request)
      }
    )
  end

  def player_rejected_clubs_notification(transfer_request)
    @transfer_request = transfer_request
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "#{request_noun(transfer_request)} abgelehnt durch Spieler: #{player_name(transfer_request)}",
      placeholders: {
        request_noun: request_noun(transfer_request),
        player_name: player_name(transfer_request)
      }
    )
  end

  def transfer_completed(transfer_request)
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = (
      transfer_request.requesting_club.notification_emails +
      transfer_request.former_club.notification_emails +
      [transfer_request.player.email, former_sa&.effective_sbk_email]
    ).compact.uniq.select(&:present?)
    return if recipients.empty?

    subject = release?(transfer_request) ? 'Spielerfreigabe erteilt' : 'Transfer vollzogen'
    templated_mail(
      to: recipients,
      subject: "#{subject}: #{player_name(transfer_request)}",
      placeholders: {
        completion_noun: subject,
        player_name: player_name(transfer_request)
      }
    )
  end

  def transfer_completed_receiving_lv(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.requesting_club.state_association&.effective_sbk_email
    return unless sbk_email.present?

    subject = release?(transfer_request) ? 'Spielerfreigabe erteilt (aufnehmender LV)' : 'Transfer vollzogen (aufnehmender LV)'
    templated_mail(
      to: sbk_email,
      subject: "#{subject}: #{player_name(transfer_request)}",
      placeholders: {
        completion_noun: subject,
        player_name: player_name(transfer_request)
      }
    )
  end

  def secondary_club_notification(transfer_request, club)
    @transfer_request = transfer_request
    @club = club
    recipients = club.notification_emails
    return if recipients.empty?

    templated_mail(
      to: recipients,
      subject: "Zusatzlizenz/Freigabe entzogen durch Transfer: #{player_name(transfer_request)}",
      placeholders: { player_name: player_name(transfer_request) }
    )
  end

  private

  def player_name(tr)
    "#{tr.player.first_name} #{tr.player.last_name}"
  end

  def release?(tr)
    tr.request_type == 'release'
  end

  def request_noun(tr)
    release?(tr) ? 'Spielerfreigabe-Antrag' : 'Transferantrag'
  end
end
