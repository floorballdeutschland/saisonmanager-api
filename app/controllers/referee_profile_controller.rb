class RefereeProfileController < ApplicationController
  before_action :authenticate_user
  before_action :require_referee_account

  # GET /api/v2/referee/profile
  def show
    render json: profile_json
  end

  # PUT /api/v2/referee/profile
  def update
    if @referee.update(profile_params)
      render json: profile_json
    else
      render json: { errors: @referee.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def require_referee_account
    @referee = current_user.referee
    return render json: { error: 'Kein Schiedsrichter-Profil verknüpft' }, status: :forbidden if @referee.nil?
  end

  # :email ist hier bewusst NICHT erlaubt: Die Adresse gehört dem Benutzerkonto
  # und wird ausschließlich über den Double-Opt-In-Flow unter „Mein Konto"
  # geändert (UserSettingsController#update_email) – die Bestätigung zieht die
  # Schiri-Adresse mit (User#confirm_email_change!).
  def profile_params
    params.require(:referee).permit(
      :vorname, :nachname, :telefonnummer,
      :strasse, :hausnummer, :plz, :ort,
      :partner_lizenznummer, :kurzfristig_mobil
    )
  end

  def profile_json
    {
      id: @referee.id,
      lizenznummer: @referee.lizenznummer,
      lizenznummer_display: @referee.lizenznummer_display,
      vorname: @referee.vorname,
      nachname: @referee.nachname,
      email: @referee.email,
      # Login-Adresse des Kontos – fürs Frontend, um bei (Alt-)Divergenz zur
      # Schiri-Adresse transparent zu machen, was unter „Mein Konto" steht.
      account_email: current_user.email,
      telefonnummer: @referee.telefonnummer,
      strasse: @referee.strasse,
      hausnummer: @referee.hausnummer,
      plz: @referee.plz,
      ort: @referee.ort,
      partner_lizenznummer: @referee.partner_lizenznummer,
      kurzfristig_mobil: @referee.kurzfristig_mobil,
      lizenzstufe: @referee.lizenzstufe,
      gueltigkeit: @referee.gueltigkeit&.strftime('%d.%m.%Y'),
      geburtsdatum: @referee.geburtsdatum&.strftime('%d.%m.%Y'),
      verein: @referee.club&.name,
      landesverband: @referee.landesverband
    }
  end
end
