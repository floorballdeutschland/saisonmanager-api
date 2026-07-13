module Admin
  class LicenseDocumentsController < ApplicationController
    before_action :set_player
    before_action :check_read_permission, only: %i[index show]
    before_action :check_write_permission, only: %i[create destroy]

    def index
      # Dokumente gelten pro Spieler (saisonübergreifend). Der license_id-Filter
      # bleibt für Alt-Aufrufer optional erhalten.
      docs = @player.license_documents.includes(file_attachment: :blob).order(created_at: :desc).to_a
      catalog = document_type_catalog(docs)
      docs = filter_documents_by_scope(docs, catalog)
      render json: docs.map { |d| document_json(d, catalog) }
    end

    def show
      doc = @player.license_documents.find(params[:id])
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless document_visible?(doc)

      redirect_to rails_blob_url(doc.file, disposition: 'inline'), allow_other_host: true
    end

    def create
      return render json: { errors: ['Datei fehlt'] }, status: :unprocessable_entity if params[:file].blank?
      return render json: { errors: ['Dokumenttyp fehlt'] }, status: :unprocessable_entity if
        params[:document_type].blank?

      doc = LicenseDocument.new(
        player: @player,
        license_id: params[:license_id].presence,
        document_type: params[:document_type],
        season_id: Setting.current_season_id,
        uploaded_by: current_user
      )
      doc.file.attach(params[:file])

      # Pro Spieler gibt es je Dokumentart genau ein aktuelles Dokument – ein
      # neuer Upload ersetzt alle vorhandenen dieser Art (auch Altbestand, der
      # noch an einer konkreten Lizenz hing). Erst löschen, dann validieren:
      # sonst schlägt die Eindeutigkeits-Validierung gegen das zu ersetzende
      # Dokument an. Bei ungültigem Upload rollt die Transaktion das Löschen
      # zurück, der Bestand bleibt unverändert.
      existing = @player.license_documents.where(document_type: params[:document_type])
      saved = false
      ActiveRecord::Base.transaction do
        existing.find_each(&:destroy)
        saved = doc.save
        raise ActiveRecord::Rollback unless saved
      end

      unless saved
        return render json: { errors: doc.errors.full_messages }, status: :unprocessable_entity
      end

      render json: document_json(doc, document_type_catalog([doc])), status: :created
    end

    def destroy
      doc = @player.license_documents.find(params[:id])
      doc.file.purge
      doc.destroy!
      render json: { success: true }
    end

    private

    def set_player
      @player = Player.find(params[:player_id])
    end

    def check_read_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def check_write_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def admin_or_sbk_for_player?
      ph = current_user.permission_hash
      return true if ph[:admin].present?

      if ph[:sbk].present?
        player_go_ids = player_game_operation_ids
        return true if ph[:sbk].include?(0)
        return true if (ph[:sbk] & player_go_ids).present?
      end

      false
    end

    def tm_for_player?
      ph = current_user.permission_hash
      return false if ph[:tm].blank?

      player_team_ids = (@player.licenses || []).filter_map { |l| l['team_id']&.to_i }
      (ph[:tm] & player_team_ids).present?
    end

    def vm_for_player?
      ph = current_user.permission_hash
      return false if ph[:vm].blank?

      # Der VM darf, wenn er (a) einen aktuell gültigen Verein des Spielers verwaltet
      # ODER (b) den Verein/Syndikat-Verein des Teams verwaltet, zu dem die Lizenz gehört.
      # (b) hält die Prüfung konsistent zu players#request_license (SG-/Syndikats-Teams:
      # der VM darf für einen Partnerclub-Spieler eine Lizenz lösen und muss deren
      # Dokumente sehen/verwalten können).
      return true if (ph[:vm] & player_active_club_ids).present?
      return true if (ph[:vm] & license_team_club_ids).present?

      false
    end

    # club_ids der aktuell gültigen Vereinsmitgliedschaften des Spielers. Die
    # valid_until-Logik ist bewusst identisch zum Rest des Systems (vgl. Player):
    # nil ODER in der Zukunft = aktiv (nicht nur nil).
    def player_active_club_ids
      (@player.clubs || []).filter_map do |c|
        next unless c['valid_until'].nil? || c['valid_until'].to_time > Time.current

        c['club_id'].to_i
      end
    end

    # club_ids (inkl. Syndikat) der Teams, zu denen die betreffende Lizenz gehört.
    # Ist license_id gesetzt (index/show/create), wird auf diese Lizenz gescoped,
    # sonst werden alle Team-Lizenzen des Spielers berücksichtigt.
    def license_team_club_ids
      licenses = @player.licenses || []
      licenses = licenses.select { |l| l['id'].to_s == params[:license_id].to_s } if params[:license_id].present?
      team_ids = licenses.filter_map { |l| l['team_id']&.to_i }
      return [] if team_ids.empty?

      Team.where(id: team_ids).flat_map(&:all_club_ids).uniq
    end

    def player_game_operation_ids
      club_ids = (@player.clubs || []).filter_map { |c| c['club_id'].to_i }
      Club.where(id: club_ids).flat_map do |club|
        club.game_operations_hash.map { |go| go['game_operation_id'].to_i }
      end.uniq
    end

    def perm_hash
      @perm_hash ||= current_user.permission_hash
    end

    # Katalog der referenzierten Dokumentarten, keyed per document_type-Key.
    # game_operation wird eager geladen, damit document_json/Scoping ohne N+1
    # auf Verband und Sichtbarkeit zugreifen können.
    def document_type_catalog(docs)
      keys = docs.map(&:document_type).uniq
      return {} if keys.empty?

      DocumentType.includes(:game_operation).where(key: keys).index_by(&:key)
    end

    # Sichtbarkeit richtet sich nach dem Katalog-Scope der Dokumentart:
    # Admin und global gescopter SBK (FD, ph[:sbk] enthält 0) sehen alles;
    # reine VM/TM-Zugriffe behalten Vollzugriff auf die Dokumente ihres
    # Spielers. Ein verbandsspezifisch gescopter SBK sieht nur globale
    # Dokumentarten und die seines/seiner Verbände.
    def unrestricted_document_access?
      return true if perm_hash[:admin].present?
      return true if perm_hash[:sbk].present? && perm_hash[:sbk].include?(0)

      perm_hash[:sbk].blank?
    end

    def filter_documents_by_scope(docs, catalog)
      return docs if unrestricted_document_access?

      sbk_go_ids = perm_hash[:sbk]
      docs.select { |doc| document_in_scope?(doc, catalog, sbk_go_ids) }
    end

    def document_visible?(doc)
      return true if unrestricted_document_access?

      document_in_scope?(doc, document_type_catalog([doc]), perm_hash[:sbk])
    end

    # Globale Dokumentarten (game_operation_id nil) und Freitext-Altbestand ohne
    # Katalogeintrag sind für alle sichtbar; verbandsspezifische nur für den
    # zuständigen Verband.
    def document_in_scope?(doc, catalog, sbk_go_ids)
      go_id = catalog[doc.document_type]&.game_operation_id
      return true if go_id.nil?

      sbk_go_ids.include?(go_id)
    end

    def document_json(doc, catalog = {})
      dt = catalog[doc.document_type]
      {
        id: doc.id,
        document_type: doc.document_type,
        document_type_name: dt&.name,
        validity: dt&.validity,
        game_operation_id: dt&.game_operation_id,
        game_operation_name: dt&.game_operation&.name,
        season_id: doc.season_id,
        filename: doc.file.filename.to_s,
        content_type: doc.file.content_type,
        byte_size: doc.file.byte_size,
        created_at: doc.created_at,
        url: rails_blob_url(doc.file, disposition: 'inline')
      }
    end
  end
end
