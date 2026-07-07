class UserMailer < ApplicationMailer
  def reset_password(user)
    @link = "#{FrontendUrl.base}/neues-passwort/#{user.password_reset_token}"
    templated_mail(to: user.email, subject: 'Anleitung zum Passwort zurücksetzen im Saisonmanager')
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
