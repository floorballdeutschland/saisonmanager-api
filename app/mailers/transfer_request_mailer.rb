class TransferRequestMailer < ApplicationMailer
  def new_request_to_former_club(transfer_request)
    @transfer_request = transfer_request
    recipients = [transfer_request.former_club.contact_email,
                  transfer_request.player.email].compact.uniq.select(&:present?)
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

  def pending_lv_notification(transfer_request)
    @transfer_request = transfer_request
    sbk_email = transfer_request.former_club.state_association&.sbk_email
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
    recipients = [
      transfer_request.requesting_club.contact_email,
      transfer_request.former_club.contact_email,
      transfer_request.player.email
    ].compact.uniq.select(&:present?)
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
    recipient = transfer_request.requesting_club.contact_email
    return unless recipient.present?

    templated_mail(
      to: recipient,
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
    recipients = [
      transfer_request.requesting_club.contact_email,
      transfer_request.former_club.contact_email
    ].compact.uniq.select(&:present?)
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
    recipients = [
      transfer_request.requesting_club.contact_email,
      transfer_request.former_club.contact_email,
      transfer_request.player.email,
      former_sa&.sbk_email
    ].compact.uniq.select(&:present?)
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
    sbk_email = transfer_request.requesting_club.state_association&.sbk_email
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
    return unless club.contact_email.present?

    templated_mail(
      to: club.contact_email,
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
