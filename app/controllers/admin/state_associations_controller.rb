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
      if (meldung = parent_move_conflict)
        return render json: { errors: [meldung] }, status: :unprocessable_entity
      end

      if @state_association.update(state_association_params)
        render json: @state_association.full_hash
      else
        render json: { errors: @state_association.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/state_associations/:id
    #
    # Auf `clubs.state_association_id` liegt kein Fremdschlüssel und kein
    # `dependent:`. Seit die Zuständigkeit daran hängt, machte ein Löschen jeden
    # Verein darunter lautlos herrenlos: Er wäre nur noch für die Bundesebene
    # sichtbar, und die einzige Spur wäre ein Log-Eintrag, den nur ein globaler
    # Zugriff auslöst (Club.log_unresolvable_state_associations). Der betroffene
    # Verband selbst sähe nichts als eine kürzere Liste.
    #
    # Auch die Unterverbände zählen: `has_many :children, dependent: :nullify`
    # macht sie parentlos, ihre Vereine wechseln damit die Zuständigkeit.
    def destroy
      vereine = Club.where(state_association_id: @state_association.id).count
      kinder = @state_association.children.count

      if vereine.positive? || kinder.positive?
        return render json: {
          errors: ["Der Landesverband trägt noch #{vereine} Verein(e) und " \
                   "#{kinder} untergeordnete(n) Verband/Verbände. Sie würden ihren " \
                   'zuständigen Spielbetrieb verlieren. Erst umhängen, dann löschen.']
        }, status: :unprocessable_entity
      end

      # Rückgabewert auswerten: `destroy` gibt bei einem abbrechenden Callback
      # `false` zurück, und die Antwort wies das vorher trotzdem als Erfolg aus.
      return head :no_content if @state_association.destroy

      render json: { errors: @state_association.errors.full_messages.presence || ['Löschen nicht möglich'] },
             status: :unprocessable_entity
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

    # Gegenstück zu ClubsController#state_association_move_conflict, für den Weg
    # über den Verband statt über den einzelnen Verein.
    #
    # Dort wird das Verschieben EINES Vereins in einen Verbund ohne Spielbetrieb
    # ausdrücklich abgelehnt, auch für die Bundesebene: Der Verein hätte danach
    # keinen zuständigen Verband. Ein Umhängen per `parent_id` verschiebt den
    # ganzen Teilbaum dorthin, und zwar bisher ohne jede Prüfung. Dieselbe Regel
    # muss deshalb hier gelten, sonst ist der Riegel am Verein nur der schmalere
    # von zwei Wegen zum selben Zustand.
    #
    # Gibt nil zurück, wenn nichts zu beanstanden ist, sonst die Meldung.
    def parent_move_conflict
      # Nur prüfen, wenn das Feld überhaupt geschrieben wird. Für alle anderen
      # verwirft `state_association_params` es stillschweigend (die Maske schickt
      # den ganzen Datensatz zurück, also auch ein `parent_id`, das der Nutzer
      # nicht bearbeiten darf). Ohne diese Klammer bekäme ein regionaler SBK eine
      # Fehlermeldung über eine Änderung, die gar nicht stattgefunden hätte.
      return nil unless nationwide_state_association_manager?

      eingereicht = params[:state_association] || {}
      return nil unless eingereicht.key?('parent_id')

      ziel_id = eingereicht['parent_id'].presence&.to_i
      return nil if ziel_id == @state_association.parent_id
      # Parentlos ist unbedenklich: Der Verband wird dann seine eigene Wurzel und
      # braucht nur selbst einen Spielbetrieb -- das prüft er über seine Vereine
      # ohnehin nicht, und ein Verband ohne Spielbetrieb ist ein bestehender,
      # sichtbarer Zustand (Club.unassigned meldet ihn).
      return nil if ziel_id.nil?

      ziel_wurzel = StateAssociation.root_id(ziel_id)
      return 'Der gewählte übergeordnete Verband existiert nicht.' if ziel_wurzel.nil?

      return nil if GameOperation.id_by_state_association[ziel_wurzel].present?

      betroffen = Club.where(state_association_id: StateAssociation.ids_under([@state_association.id])).count
      "Für den gewählten Verbund ist kein Spielbetrieb zuständig. #{betroffen} Verein(e) " \
        'würden dadurch ihren zuständigen Verband verlieren.'
    end

    def state_association_params
      permitted = %i[name short_name vsk_email sbk_email rsk_email scan_required
                     express_license_enabled referee_license_review_enabled
                     manual_proceeding_creation referee_assignment_enabled
                     referee_assignment_external_enabled person_level_assignment_default
                     report_form_email_enabled
                     logo banner_link_url]
      # Den übergeordneten Verband darf nur die Bundesebene (um-)hängen, und zwar
      # ausdrücklich strenger als beim übrigen Schreibzugriff: siehe
      # #nationwide_state_association_manager?. Ein regional gescopter Admin darf
      # jeden Landesverband bearbeiten (Bestandsverhalten), aber nicht die
      # Zuständigkeit für dessen Vereine zu sich holen.
      #
      # Seit die Zuständigkeit für Vereine am Landesverband hängt
      # (Club#main_game_operation_id), verschiebt ein Umhängen die Verwaltung
      # ALLER Vereine im Teilbaum in einen anderen Spielbetrieb. Vorher entschied
      # `parent_id` nur über Gruppierung und Postfach-Vererbung.
      permitted << :parent_id if nationwide_state_association_manager?
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
      # Der Block „Einstellungen" (StateAssociation::INHERITED_SETTINGS, gelesen
      # über die effective_*-Methoden) wird in zwei Fällen verworfen. Die Maske
      # sperrt die Felder in beiden, ein direkter API-Aufruf umgeht sie.
      #
      # (a) Ein übergeordneter Verbund hängt dran: Dann kommen die Werte von
      #     dort. Verworfen und nicht auf false gezwungen -- nimmt ein Admin den
      #     Verbund später weg, steht der früher gepflegte eigene Stand wieder
      #     da, statt still überall aus zu sein. Gelesen wird er ohnehin nicht,
      #     solange der Verbund hängt.
      # (b) Der Nutzer darf die Einstellungen dieses Verbands nicht setzen, weil
      #     sie für dessen ganzen Teilbaum gälten. Siehe
      #     StateAssociationWritable#settings_writable_state_associations.
      if inherits_settings?(attrs) || !settings_writable?(@state_association)
        StateAssociation::INHERITED_SETTINGS.each { |key| attrs.delete(key) }
      else
        normalize_referee_assignment_switches!(attrs)
      end
      attrs
    end

    # Hat der Landesverband nach diesem Update einen übergeordneten Verbund?
    #
    # Nicht schlicht `attrs[:parent_id].present?`: parent_id darf nur ein globaler
    # Admin schicken, `permit` streicht den Schlüssel allen anderen. Ohne den
    # Rückfall auf den gespeicherten Stand könnte ein regionaler SBK die
    # Einstellungen seines Kind-LV weiterhin überschreiben – genau der Fall, den
    # diese Sperre verhindern soll. Beim Anlegen gibt es noch keinen Datensatz,
    # dann entscheidet allein der Parameter.
    def inherits_settings?(attrs)
      return attrs[:parent_id].present? if attrs.key?(:parent_id)

      @state_association&.parent_id.present?
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
