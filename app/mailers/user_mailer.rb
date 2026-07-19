class UserMailer < ApplicationMailer
  def reset_password(user)
    @link = "#{FrontendUrl.base}/neues-passwort/#{user.password_reset_token}"
    @username = user.user_name
    templated_mail(
      to: user.email,
      subject: 'Anleitung zum Passwort zurücksetzen im Saisonmanager',
      placeholders: { username: @username, link: @link }
    )
  end

  # Bestätigungslink für eine E-Mail-Änderung: geht an die NEUE Adresse
  # (pending_email); die Änderung wird erst nach Klick auf den Link wirksam
  # (24h gültig, siehe User::EMAIL_CONFIRMATION_VALIDITY).
  def confirm_email_change(user, raw_token)
    @link = "#{FrontendUrl.base}/email-bestaetigen?token=#{raw_token}"
    @username = user.user_name
    @new_email = user.pending_email
    templated_mail(
      to: user.pending_email,
      subject: 'Bestätige deine neue E-Mail-Adresse im Saisonmanager',
      placeholders: { username: @username, link: @link, new_email: @new_email }
    )
  end

  # Begrüßungs-Mail beim Anlegen eines Schiedsrichter-Benutzerkontos: enthält den
  # Benutzernamen und einen Link zum (erstmaligen) Setzen des Passworts – bewusst
  # KEINE „Passwort vergessen"-Mail, da der Account gerade neu erstellt wurde.
  def referee_account_created(user)
    @link = "#{FrontendUrl.base}/neues-passwort/#{user.password_reset_token}"
    @username = user.user_name
    templated_mail(
      to: user.email,
      subject: 'Dein Schiedsrichteraccount im Saisonmanager',
      placeholders: { username: @username, link: @link }
    )
  end
end
