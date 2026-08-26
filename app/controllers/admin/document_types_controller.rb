module Admin
  # Verwaltung des Dokumentarten-Katalogs (Lizenz-Pflichtdokumente).
  # Lesen: Admin und SBK (für Liga-Formular und Lizenzansichten); verbands-
  # gescopte SBK sehen den eigenen Verband + globale Einträge.
  # Pflegen (anlegen/ändern/löschen): nur Admin und global (bundesweit)
  # gescopte SBK (SBK FD). Verbands-gescopte SBK haben ausschließlich
  # Lesezugriff – neue Dokumentarten werden bei sbk@floorball.de beantragt.
  class DocumentTypesController < ApplicationController
    include LicenseDocumentPresentation

    before_action :authorize_read!, only: :index
    before_action :authorize_manage!, only: %i[create update destroy]
    before_action :set_document_type, only: %i[update destroy]

    def index
      types = scoped_sbk? ? DocumentType.for_game_operations(sbk_go_ids) : DocumentType.all
      # Nur die aktuellen Fassungen: Archivierte (abgelöste oder als Nachweis
      # aufbewahrte) Zeilen sind kein Bestand, den die Katalogansicht als
      # "so oft hochgeladen" ausweisen soll. Der Löschschutz `in_use?` zählt
      # bewusst anders – eine Art ohne aktuelle Uploads kann sich deshalb als
      # unbenutzt zeigen und trotzdem nicht löschbar sein.
      upload_counts = LicenseDocument.active.group(:document_type).count
      league_counts = league_usage_counts

      render json: types.order(:name).map { |dt|
        document_type_json(dt).merge(
          usage_count: upload_counts[dt.key].to_i,
          league_count: league_counts[dt.key].to_i
        )
      }
    end

    def create
      document_type = DocumentType.new(document_type_params)
      if document_type.save
        render json: document_type_json(document_type), status: :created
      else
        render json: { errors: document_type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      attrs = document_type_params
      @document_type.assign_attributes(attrs)

      if @document_type.save
        # Erst nach erfolgreichem Save löschen – sonst wäre die Vorlage bei
        # fehlgeschlagener Validierung trotzdem weg. Ein gleichzeitig
        # hochgeladenes neues Template hat Vorrang.
        @document_type.template.purge if params[:remove_template].present? && attrs[:template].blank?
        render json: document_type_json(@document_type)
      else
        render json: { errors: @document_type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      if in_use?(@document_type)
        # Die Verwendungszahl der Liste zaehlt nur aktive Uploads, dieser Riegel
        # auch archivierte Nachweise. Ohne den Zusatz stuende die SBK vor einer
        # Art mit "0 Uploads, 0 Ligen", die sich trotzdem nicht loeschen laesst.
        return render json: { error: 'Dokumentart wird bereits verwendet (aktuelle oder archivierte Uploads oder Liga-Konfiguration) und kann nicht gelöscht werden.' },
                      status: :unprocessable_entity
      end

      @document_type.destroy!
      head :no_content
    end

    private

    def document_type_params
      params.require(:document_type).permit(:name, :description, :game_operation_id, :validity,
                                            :required_below_age, :required_from_birth_year, :template)
    end

    def set_document_type
      @document_type = DocumentType.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Dokumentart nicht gefunden' }, status: :not_found
    end

    def authorize_read!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Pflegen dürfen nur Admin und global gescopte SBK (SBK FD, game_operation_id 0).
    # Verbands-gescopte SBK haben nur Lesezugriff.
    def authorize_manage!
      ph = current_user.permission_hash
      return if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def scoped_sbk?
      ph = current_user.permission_hash
      ph[:admin].blank? && ph[:sbk].present? && ph[:sbk].exclude?(0)
    end

    def sbk_go_ids
      current_user.permission_hash[:sbk] || []
    end

    def in_use?(document_type)
      # Hier bewusst OHNE .active: Auch eine archivierte Fassung verweist über
      # den Key auf die Dokumentart. Verschwindet die Art aus dem Katalog, liest
      # der Nachweis sich nur noch als Freitext-Altbestand.
      return true if LicenseDocument.exists?(document_type: document_type.key)

      league_usage_counts[document_type.key].to_i.positive?
    end

    def league_usage_counts
      @league_usage_counts ||= League.where("required_documents <> '{}'")
                                     .pluck(:required_documents)
                                     .flatten
                                     .tally
    end
  end
end
