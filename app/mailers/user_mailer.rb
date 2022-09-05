class UserMailer < ApplicationMailer
  def reset_password(user)
    @link = "https://saisonmanager.de/neues-passwort/#{user.password_reset_token}"
    mail(to: user.email, subject: 'Anleitung zum Passwort zurücksetzen im Saisonmanager')
  end
end
