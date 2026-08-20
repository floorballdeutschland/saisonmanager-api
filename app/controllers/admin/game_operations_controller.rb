module Admin
  # Verwaltung der Spielbetriebe selbst -- Anlegen, Stammdaten, oeffentlicher
  # Pfad, Landesverband, `national`. Vorher gab es das nur in der Rails-Konsole
  # (Issue #492); die Oberflaeche kannte Spielbetriebe ausschliesslich als
  # Auswahlliste (GameOperationsController#admin_game_operations, die weiterhin
  # die Liste fuer diese Maske liefert) und die Banner-Pflege
  # (GameOperationsController#admin_upload_banner und Nachbarn, unveraendert und
  # von derselben Maske bedient).
  #
  # Durchgehend BUNDESWEITEN Admins vorbehalten, strenger als die uebrige
  # Verbandsverwaltung. Grund sind die beiden Felder, die Zustaendigkeit
  # verschieben:
  #
  # * `state_association_id` bestimmt, fuer welchen Verbandsbaum dieser
  #   Spielbetrieb zustaendig ist (Club#main_game_operation_id loest ueber
  #   GameOperation.id_by_state_association auf). Wer es setzt, holt sich die
  #   Vereine eines fremden Verbunds samt Stammdaten, Rollenvergabe, Transfers
  #   und Spielersperren -- dieselbe Reichweite wie `parent_id` am
  #   Landesverband, das aus genau diesem Grund an
  #   StateAssociationWritable#nationwide_state_association_manager? haengt.
  # * `national` hebt SBK, RSK und Ansetzer dieses Spielbetriebs auf globalen
  #   Scope (User#permission_hash).
  #
  # Ein regional gescopter Admin ist ein bestehender Zustand (permission_hash
  # hebt ph[:admin] nur dann auf [0], wenn die Rolle alle Spielbetriebe traegt),
  # und er darf hier deshalb nichts -- auch nicht lesen, damit die Maske nicht
  # Felder anzeigt, die das Speichern verweigert.
  class GameOperationsController < ApplicationController
    before_action :authorize_nationwide_admin!
    before_action :set_game_operation, only: %i[show update destroy]

    # GET /api/v2/admin/game_operations/:id
    def show
      render json: @game_operation.admin_hash
    end

    # POST /api/v2/admin/game_operations
    def create
      go = GameOperation.new(game_operation_params)
      if go.save
        flush_init_cache
        render json: go.admin_hash, status: :created
      else
        render json: { errors: go.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/game_operations/:id
    def update
      if (meldung = state_association_move_conflict)
        return render json: { errors: [meldung] }, status: :unprocessable_entity
      end

      if @game_operation.update(game_operation_params)
        flush_init_cache
        render json: @game_operation.admin_hash
      else
        render json: { errors: @game_operation.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/game_operations/:id
    #
    # Drei Riegel, und keiner davon ist Vorsicht auf Vorrat -- auf
    # `leagues.game_operation_id` und `users.permissions` liegt kein
    # Fremdschluessel, und die Vereinszuordnung ist abgeleitet:
    #
    # * Ligen verlieren ihren Verband. `League#game_operation` ist an Dutzenden
    #   Stellen der Rechtepruefung die Quelle der game_operation_id.
    # * Vereine verlieren ihren zustaendigen Verband und sind nur noch fuer die
    #   Bundesebene sichtbar -- lautlos, siehe Club#main_game_operation_id.
    # * Rollen in `users.permissions` zeigen auf eine ID, die es nicht mehr gibt.
    #   Der Nutzer behaelt seinen Menuepunkt und sieht nichts mehr.
    def destroy
      counts = @game_operation.dependency_counts
      if counts.values.any?(&:positive?)
        return render json: { errors: [deletion_conflict_message(counts)] }, status: :unprocessable_entity
      end

      # Rueckgabewert auswerten: `destroy` gibt bei einem abbrechenden Callback
      # `false` zurueck, ohne eine Ausnahme zu werfen.
      if @game_operation.destroy
        flush_init_cache
        return head :no_content
      end

      render json: { errors: @game_operation.errors.full_messages.presence || ['Löschen nicht möglich'] },
             status: :unprocessable_entity
    end

    private

    def set_game_operation
      @game_operation = GameOperation.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Spielbetrieb nicht gefunden' }, status: :not_found
    end

    def game_operation_params
      params.require(:game_operation).permit(:name, :short_name, :path, :national,
                                             :state_association_id, :banner_link_url)
    end

    # Beim Umhaengen auf einen anderen Landesverband wechselt die Zustaendigkeit
    # fuer ganze Verbandsbaeume. Die Zahlen kommen in die Meldung, damit die
    # Reichweite vor dem Speichern dasteht und nicht erst hinterher an einer
    # kuerzeren Vereinsliste auffaellt.
    #
    # Abgelehnt wird nur der Fall, der Vereine herrenlos macht: Der Spielbetrieb
    # ist heute fuer Vereine zustaendig und soll auf einen Landesverband
    # wechseln (oder gar keinen), der nicht die Wurzel seines Verbandsbaums ist.
    # Ein Spielbetrieb an einem untergeordneten Verband hat keine Vereine
    # (GameOperation#home_clubs), die bisherigen faenden also keinen Nachfolger.
    def state_association_move_conflict
      eingereicht = params[:game_operation] || {}
      return nil unless eingereicht.key?('state_association_id')

      ziel_id = eingereicht['state_association_id'].presence&.to_i
      return nil if ziel_id == @game_operation.state_association_id

      betroffen = Club.home_clubs_of([@game_operation.id]).count
      return nil if betroffen.zero?

      if ziel_id.nil?
        return "Für diesen Spielbetrieb sind #{betroffen} Verein(e) zuständig. Ohne Landesverband " \
               'verlieren sie ihren zuständigen Verband. Erst die Vereine umhängen, dann das Feld leeren.'
      end

      ziel_wurzel = StateAssociation.root_id(ziel_id)
      return 'Der gewählte Landesverband existiert nicht.' if ziel_wurzel.nil?
      return nil if ziel_wurzel == ziel_id

      'Der gewählte Landesverband hat einen übergeordneten Verbund. Zuständig ist immer der ' \
        "Spielbetrieb der Wurzel des Verbandsbaums, dieser Spielbetrieb hätte danach keine Vereine mehr – " \
        "die heutigen #{betroffen} verlieren ihren zuständigen Verband."
    end

    def deletion_conflict_message(counts)
      teile = []
      teile << "#{counts[:leagues]} Liga/Ligen" if counts[:leagues].positive?
      teile << "#{counts[:clubs]} Verein(e)" if counts[:clubs].positive?
      teile << "#{counts[:users]} Benutzerrolle(n)" if counts[:users].positive?

      "Am Spielbetrieb hängen noch #{teile.to_sentence}. Sie würden ihren Verband verlieren " \
        'beziehungsweise ins Leere zeigen. Erst umhängen, dann löschen.'
    end

    # Die Spielbetriebe stecken in /api/v2/init, das der Endpunkt 30 Minuten
    # zwischenspeichert. Ohne Leerung zeigt die oeffentliche Seite den alten
    # Stand, und beim Anlegen fehlt der neue Verband eine halbe Stunde in jeder
    # Auswahl. Der Verbandsbaum in `Current` ist davon unabhaengig und wird vom
    # after_commit des Modells zurueckgesetzt.
    def flush_init_cache
      Rails.cache.delete('settings/init')
    end

    def authorize_nationwide_admin!
      return if nationwide_admin?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Nur `0` im Admin-Scope, also wirklich bundesweit. Absichtlich NICHT
    # nationwide_state_association_manager? aus StateAssociationWritable: das
    # laesst auch einen global gescopten SBK durch, und der soll Spielbetriebe
    # nicht anlegen koennen (Issue #492: „Nur für Admin, nicht für SBK").
    def nationwide_admin?
      Array(current_user.permission_hash[:admin]).include?(0)
    end
  end
end
