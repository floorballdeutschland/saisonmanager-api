module Admin
  class PlayerChangeRequestsController < ApplicationController
    # membership_current? – Gültigkeit einer Zugehörigkeit, mit Meldung statt
    # 500er bei unlesbarem valid_until.
    include LicenseAccessScope

    def index
      ph = current_user.permission_hash
      # Rollen additiv auswerten: ein Nutzer mit SBK- *und* VM-Rolle sah sonst
      # nur den SBK-Ausschnitt und verlor die Anträge des eigenen Vereins,
      # sobald dieser außerhalb des SBK-Spielbetriebs liegt.
      requests = if ph[:admin].present?
                   PlayerChangeRequest.all
                 else
                   scopes = []
                   scopes << PlayerChangeRequest.for_go(ph[:sbk]) if ph[:sbk].present?
                   scopes << PlayerChangeRequest.for_club(ph[:vm]) if ph[:vm].present?
                   return render json: [], status: :ok if scopes.empty?

                   scopes.reduce { |combined, scope| combined.or(scope) }
                 end

      render json: requests.order(created_at: :desc).includes(:player, :club, :secondary_player)
    end

    def create
      ph = current_user.permission_hash

      # Der Verein kommt als JSON-Zahl (so schickt es die Oberfläche) oder als
      # Zeichenkette (Formular-Post). Ein Array brach hier mit
      # "undefined method `to_i' for [\"1\"]:Array" ab, also einem 500er allein
      # durch die Nutzlast. Kein Sicherheitsproblem, aber eine unnötige Meldung
      # in der Fehlerüberwachung, und die Zuständigkeitsprüfung darunter hängt
      # an diesem Wert.
      club_id = params[:club_id]
      club_id = club_id.to_i if club_id.is_a?(String) || club_id.is_a?(Integer)
      unless club_id.is_a?(Integer) && club_id.positive?
        return render json: { error: 'Verein fehlt oder ist ungültig' }, status: :unprocessable_entity
      end

      unless ph[:admin].present? || ph[:vm]&.include?(club_id)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      player = Player.find_by(id: params[:player_id])
      return render json: { error: 'Spieler nicht gefunden' }, status: :not_found unless player

      # Anträge nur für Spieler des eigenen Vereins, und zwar für JEDE Antragsart.
      # Vorher griff der Guard nur bei 'merge': gegen birthdate, first_name,
      # last_name, names_swapped, nationality und gender ließ sich ein Antrag zu
      # jeder beliebigen Spieler-ID im System stellen, auch zu Spielern, mit denen
      # der Verein nie etwas zu tun hatte. Entschieden wird zwar durch die SBK,
      # die bekam aber einen plausibel aussehenden Antrag vorgelegt.
      unless membership_grants_access?(player, club_id)
        return render json: { error: 'Spieler gehört nicht zum angegebenen Verein' }, status: :forbidden
      end

      # Beim Merge dieselbe Frage für das Duplikat. Die Modell-Validierung
      # merge_must_be_executable prüft das ebenfalls, aber ohne Gültigkeit; sie
      # bleibt als Auffangnetz für Konsole und Skripte stehen, weil die
      # Datumsauswertung samt rescue und Meldung sonst ins Modell zu kopieren
      # wäre (genau die Doppelung, die #397 als Fehler benennt).
      #
      # 422 mit errors[] wie die Modell-Validierung, bewusst kein 403: Der
      # ErrorInterceptor im Frontend führt bei 403 auf die Startseite, und
      # player_change_requests steht nicht in seiner Ausnahmeliste. Eine
      # unpassende Auswahl im Duplikat-Feld darf nicht aus der Bearbeitung
      # werfen.
      if params[:correction_type] == 'merge' && (secondary = find_secondary_player) &&
         !membership_grants_access?(secondary, club_id)
        return render json: { errors: ['Das Duplikat gehört nicht zum angegebenen Verein'] },
                      status: :unprocessable_entity
      end

      request = PlayerChangeRequest.new(
        player: player,
        club_id: club_id,
        correction_type: params[:correction_type],
        new_value: params[:new_value].presence,
        secondary_player_id: params[:secondary_player_id].presence,
        status: 'pending',
        requested_by_user_id: current_user.id
      )

      if request.save
        render json: request, status: :created
      else
        render json: { errors: request.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def approve
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      request = PlayerChangeRequest.find(params[:id])
      unless ph[:admin].present? || sbk_can_access_request?(ph, request)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end
      return render json: { error: 'Antrag nicht mehr ausstehend' }, status: :unprocessable_entity unless request.status == 'pending'

      PlayerChangeRequest.transaction do
        request.apply!(current_user.id)
      end

      render json: request
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    def reject
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      request = PlayerChangeRequest.find(params[:id])
      unless ph[:admin].present? || sbk_can_access_request?(ph, request)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end
      return render json: { error: 'Antrag nicht mehr ausstehend' }, status: :unprocessable_entity unless request.status == 'pending'

      if request.update(status: 'rejected', rejection_reason: params[:rejection_reason], reviewed_by_user_id: current_user.id)
        render json: request
      else
        render json: { errors: request.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    # nil, wenn keine ID mitkam oder sie ins Leere zeigt: Beides ist Sache der
    # Modell-Validierung (secondary_player ist beim Merge Pflicht) und soll hier
    # nicht zu einer anderen Meldung führen als bisher.
    def find_secondary_player
      return nil if params[:secondary_player_id].blank?

      Player.find_by(id: params[:secondary_player_id])
    end

    # Deckt eine Zugehörigkeit den Antrag? Vorher genügte jeder je bestandene
    # Eintrag im clubs-Hash: Der VM eines Vereins, den der Spieler 2023 verlassen
    # hat, konnte damit einen Antrag gegen ihn stellen, und beim Merge lief auf
    # Genehmigung merge_into!, was das Zweitprofil deaktiviert.
    #
    # Zwei Fälle zählen, genau wie in Club#players(include_deactivated: true),
    # aus dem die VM-Spielerliste kommt:
    #
    # (a) Die Zugehörigkeit gilt noch (valid_until leer oder nicht vor heute).
    # (b) Sie wurde erst von der Deaktivierung des Profils geschlossen. Ohne (b)
    #     stünde ein deaktivierter Spieler des eigenen Vereins in der Liste,
    #     wäre aber nicht mehr korrigierbar – deactivate! schließt alle
    #     Zugehörigkeiten.
    #
    # Stichtag ist Date.current über membership_current?, nicht Time.now: Eine
    # heute um 23:59 endende Zugehörigkeit gilt heute noch.
    def membership_grants_access?(player, club_id)
      Array(player.clubs).any? do |entry|
        next false unless entry.is_a?(Hash)
        next false unless entry['club_id'].to_i == club_id

        membership_current?(player, entry['valid_until']) ||
          player.membership_closed_by_deactivation?(entry)
      end
    end

    # Analog zu PlayerChangeRequest.for_go: Ein nicht-globaler SBK darf nur
    # Anträge entscheiden, deren Verein in seinem game_operation-Scope liegt.
    def sbk_can_access_request?(perm_hash, request)
      return false unless perm_hash[:sbk].present?
      return true if perm_hash[:sbk].include?(0)

      club = Club.find_by(id: request.club_id)
      club.present? && perm_hash[:sbk].include?(club.main_game_operation_id)
    end
  end
end
