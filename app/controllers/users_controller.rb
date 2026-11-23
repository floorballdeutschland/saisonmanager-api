class UsersController < ApplicationController
  skip_before_action :authenticate_user, only: %i[reset_password_token]
  # GET /users
  def index
    # Nur Admin/SBK dürfen die vollständige Benutzerliste abrufen (Legacy-Endpoint;
    # das Frontend nutzt sonst admin/users). Ohne Gate leakt jeder eingeloggte
    # Nutzer alle Konten inkl. sensibler Felder.
    ph = current_user.permission_hash
    return render json: { success: false, message: 'Nicht berechtigt' }, status: :forbidden unless ph[:admin].present? || ph[:sbk].present?

    @users = User.all.order(:user_name)

    # Passwort-Hash und Reset-Digest niemals ausliefern.
    render json: @users.as_json(except: %i[password_digest password_reset_token_digest password_reset_expires_at])
  end

  def reset_password_token
    # Leere Tokens, abgelaufene Links und archivierte Konten weist
    # User.find_by_password_reset_token ab.
    user = User.find_by_password_reset_token(params[:reset_token])

    unless user
      return render json: { success: false, message: 'Ungültiger oder abgelaufener Link.' }, status: :not_found
    end

    # Dieselben Regeln wie beim Ändern unter „Mein Konto" (PasswordPolicy);
    # has_secure_password prüft nur Anwesenheit und Bestätigung, nicht die Güte.
    policy_error = PasswordPolicy.error_for(params.dig(:user, :password))
    if policy_error
      return render json: { success: false, message: policy_error }, status: :unprocessable_entity
    end

    user.assign_attributes(reset_password_params)
    user.clear_password_reset_token
    if user.save
      render json: { success: true }
    else
      render json: user.errors, status: :unprocessable_entity
    end
  end

  def reset_password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
