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

    # password_digest und password_reset_token niemals ausliefern.
    render json: @users.as_json(except: %i[password_digest password_reset_token])
  end

  def reset_password_token
    # Leere/fehlende Tokens würden per find_by(password_reset_token: nil) das erste
    # Konto ohne Token (meist Admin) treffen → Account-Übernahme. Daher zuerst
    # Token normalisieren und fehlenden Treffer als ungültigen Link abweisen.
    token = params[:reset_token].presence
    user = token && User.find_by(password_reset_token: token)

    unless user
      return render json: { success: false, message: 'Ungültiger oder abgelaufener Link.' }, status: :not_found
    end

    if user.update(reset_password_params) && user.update(password_reset_token: nil)
      render json: { success: true }
    else
      render json: user.errors, status: :unprocessable_entity
    end
  end

  def reset_password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
