class TransferRequestMailer < ApplicationMailer
  def new_request_to_former_club(transfer_request)
    @transfer_request = transfer_request
    recipients = [transfer_request.former_club.contact_email,
                  transfer_request.player.email].compact.uniq.select(&:present?)
    return if recipients.empty?

    mail(
      to: recipients,
      subject: "Neue Transferanfrage: #{player_name(transfer_request)}"
    )
  end

  def pending_lv_notification(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.former_club.state_association&.sbk_email
    return unless sbk_email.present?

    mail(
      to: sbk_email,
      subject: "Transferantrag zur Genehmigung: #{player_name(transfer_request)}"
    )
  end

  def clubs_informed_lv_pending(transfer_request)
    @transfer_request = transfer_request
    recipients = [
      transfer_request.requesting_club.contact_email,
      transfer_request.former_club.contact_email,
      transfer_request.player.email
    ].compact.uniq.select(&:present?)
    return if recipients.empty?

    mail(
      to: recipients,
      subject: "Transferantrag liegt beim Landesverband: #{player_name(transfer_request)}"
    )
  end

  def rejected_notification(transfer_request)
    @transfer_request = transfer_request
    recipient = transfer_request.requesting_club.contact_email
    return unless recipient.present?

    mail(
      to: recipient,
      subject: "Transferantrag abgelehnt: #{player_name(transfer_request)}"
    )
  end

  def transfer_completed(transfer_request)
    @transfer_request = transfer_request
    former_sa = transfer_request.former_club.state_association
    recipients = [
      transfer_request.requesting_club.contact_email,
      transfer_request.former_club.contact_email,
      transfer_request.player.email,
      former_sa&.sbk_email
    ].compact.uniq.select(&:present?)
    return if recipients.empty?

    mail(
      to: recipients,
      subject: "Transfer vollzogen: #{player_name(transfer_request)}"
    )
  end

  def transfer_completed_receiving_lv(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.requesting_club.state_association&.sbk_email
    return unless sbk_email.present?

    mail(
      to: sbk_email,
      subject: "Transfer vollzogen (aufnehmender LV): #{player_name(transfer_request)}"
    )
  end

  def secondary_club_notification(transfer_request, club)
    @transfer_request = transfer_request
    @club = club
    return unless club.contact_email.present?

    mail(
      to: club.contact_email,
      subject: "Zweitlizenz/Freigabe entzogen durch Transfer: #{player_name(transfer_request)}"
    )
  end

  private

  def player_name(tr)
    "#{tr.player.first_name} #{tr.player.last_name}"
  end
end
