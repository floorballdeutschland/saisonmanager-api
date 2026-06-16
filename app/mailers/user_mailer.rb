class UserMailer < ApplicationMailer
  def reset_password(user)
    @link = "https://saisonmanager.org/neues-passwort/#{user.password_reset_token}"
    templated_mail(to: user.email, subject: 'Anleitung zum Passwort zurücksetzen im Saisonmanager')
  end
end
