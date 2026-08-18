module Admin
  class StateAssociationsController < ApplicationController
    include StateAssociationWritable

    # Eigene Grenze statt des geteilten LOGO_MAX_SIZE: Verbandslogos werden in
    # höherer Auflösung gepflegt als Vereinslogos. Entspricht dem Wert, der hier
    # vorher direkt in der Aktion stand. Das Banner nutzt die geteilte
    # BANNER_MAX_SIZE aus dem ApplicationController.
    SA_LOGO_MAX_SIZE = 5.megabytes

    before_action :authorize_sa_access!
    before_action :set_state_association, only: %i[show update destroy upload_banner delete_banner upload_logo delete_logo]
    # Anlegen/Löschen ganzer Landesverbände bleibt globalen Admins vorbehalten.
    before_action :authorize_admin!, only: %i[create destroy]
    # Eigene LV-Verwaltung (Stammdaten, Logo, Banner) ist zusätzlich für den
    # SBK des jeweiligen Landesverbands erlaubt. Muss nach set_state_association
    # laufen, da @state_association für den Scope-Check benötigt wird.
    before_action :authorize_state_association_write!,
                  only: %i[update upload_banner delete_banner upload_logo delete_logo]

    # GET /api/v2/admin/state_associations
    def index
      ph = current_user.permission_hash
      if ph[:admin].present?
        render json: StateAssociation.with_attached_logo.order(:name).map(&:short_hash)
      else
        render json: scoped_state_associations.with_attached_logo.order(:name).map(&:short_hash)
      end
    end

    # GET /api/v2/admin/state_associations/:id
    def show
      ph = current_user.permission_hash
      unless ph[:admin].present? || scoped_state_associations.exists?(@state_association.id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      render json: @state_association.full_hash(season_id: params[:season_id])
    end

    # POST /api/v2/admin/state_associations
    def create
      sa = StateAssociation.new(state_association_params)
      if sa.save
        render json: sa.full_hash, status: :created
      else
        render json: { errors: sa.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/state_associations/:id
    def update
      if @state_association.update(state_association_params)
        render json: @state_association.full_hash
      else
        render json: { errors: @state_association.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/state_associations/:id
    def destroy
      @state_association.destroy
      head :no_content
    end

    # POST /api/v2/admin/state_associations/:id/upload_banner
    def upload_banner
      return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:banner].present?

      if (error = logo_upload_error(params[:banner], square: false, max_size: BANNER_MAX_SIZE))
        return render json: { message: error }, status: :unprocessable_entity
      end

      begin
        @state_association.banner.attach(params[:banner])
        Rails.cache.delete('settings/init')
        render json: { banner_url: @state_association.banner_url }
      rescue StandardError => e
        Rails.logger.error("Banner-Upload fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
        render json: { message: 'Banner konnte nicht gespeichert werden.' }, status: :internal_server_error
      end
    end

    # DELETE /api/v2/admin/state_associations/:id/banner
    def delete_banner
      @state_association.banner.purge
      Rails.cache.delete('settings/init')
      render json: { success: true }
    rescue StandardError => e
      Rails.logger.error("Banner-Löschen fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
      render json: { message: 'Banner konnte nicht gelöscht werden.' }, status: :internal_server_error
    end

    # POST /api/v2/admin/state_associations/:id/upload_logo
    def upload_logo
      return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:logo].present?

      if (error = logo_upload_error(params[:logo], square: false, max_size: SA_LOGO_MAX_SIZE))
        return render json: { message: error }, status: :unprocessable_entity
      end

      begin
        @state_association.logo.attach(params[:logo])
        Rails.cache.delete('settings/init')
        render json: { logo_url: @state_association.logo_url }
      rescue StandardError => e
        Rails.logger.error("Logo-Upload fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
        render json: { message: 'Logo konnte nicht gespeichert werden.' }, status: :internal_server_error
      end
    end

    # DELETE /api/v2/admin/state_associations/:id/logo
    def delete_logo
      @state_association.logo.purge
      Rails.cache.delete('settings/init')
      render json: { success: true }
    rescue StandardError => e
      Rails.logger.error("Logo-Löschen fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
      render json: { message: 'Logo konnte nicht gelöscht werden.' }, status: :internal_server_error
    end

    private

    def set_state_association
      @state_association = StateAssociation.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Landesverband nicht gefunden' }, status: :not_found
    end

    def state_association_params
      permitted = %i[name short_name vsk_email sbk_email rsk_email scan_required
                     express_license_enabled referee_license_review_enabled
                     manual_proceeding_creation referee_assignment_enabled
                     referee_assignment_external_enabled person_level_assignment_default
                     report_form_email_enabled
                     logo banner_link_url]
      # Den übergeordneten Verband darf nur ein globaler Admin (um-)hängen.
      permitted << :parent_id if current_user.permission_hash[:admin].present?
      # Der Zuständigkeitsbereich ebenso, und aus einem strengeren Grund als bei
      # parent_id: an den Bundesländern soll künftig hängen, wer einen Spielort
      # zusammenführen, löschen und abschalten darf (#468 – heute entscheidet
      # das noch allein authorize_arena_lifecycle!). Dürfte ein regionaler SBK
      # sein eigenes Feld pflegen, könnte er sich fremde Bundesländer eintragen
      # und sich damit selbst Zugriff auf die Spielorte anderer Verbände geben.
      # Anders als das Ändern einer Spielort-Anschrift, das bewusst in Kauf
      # genommen ist, wäre das dauerhaft und flächig.
      #
      # Schreibweise und Reihenfolge räumt das Modell auf (normalize_states),
      # damit Rake-Task und Konsole dieselbe Invariante halten. Hier steht nur
      # die Rechteentscheidung.
      #
      # Zu wenig statt zu viel: schickt ein direkter API-Aufruf `states` als
      # Skalar oder mit einem Nicht-String darin, verwirft `permit` den ganzen
      # Schlüssel und der gespeicherte Wert bleibt unverändert stehen.
      permitted << { states: [] } if current_user.permission_hash[:admin].present?
      attrs = params.require(:state_association).permit(*permitted)
      # Kontrollprozess-Flag wird ausschließlich am Root-Landesverband
      # konfiguriert; ein Kind erbt den Wert über
      # `effective_referee_license_review_enabled`.
      attrs[:referee_license_review_enabled] = false if attrs[:parent_id].present?
      normalize_referee_assignment_switches!(attrs)
      attrs
    end

    # Die drei Ansetzungs-Optionen sind gestaffelt: die Personenebene setzt den
    # Hauptschalter voraus, die Voreinstellung die Personenebene. Die Maske graut
    # das aus, ein API-Aufruf umgeht sie. Statt die widersprüchliche Kombination
    # zu speichern und überall beim Lesen zu entschärfen, wird sie hier
    # aufgeräumt – sonst taucht ein „aus" gesetzter Schalter beim
    # Wiedereinschalten des Hauptschalters unerwartet aktiv wieder auf.
    def normalize_referee_assignment_switches!(attrs)
      main = switch_value(attrs, :referee_assignment_external_enabled)
      attrs[:referee_assignment_enabled] = false unless main

      person = switch_value(attrs, :referee_assignment_enabled)
      attrs[:person_level_assignment_default] = false unless main && person
    end

    # Wert eines Schalters nach diesem Update: aus den Parametern, wenn er
    # mitgeschickt wurde, sonst der gespeicherte Stand (nil beim Anlegen).
    def switch_value(attrs, key)
      return ActiveModel::Type::Boolean.new.cast(attrs[key]) if attrs.key?(key)

      @state_association&.public_send(key)
    end

    def authorize_sa_access!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
