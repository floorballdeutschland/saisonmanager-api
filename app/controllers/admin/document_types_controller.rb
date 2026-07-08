module Admin
  # Verwaltung des Dokumentarten-Katalogs (Lizenz-Pflichtdokumente).
  # Lesen: Admin und SBK (für Liga-Formular und Lizenzansichten).
  # Pflegen: Admin überall; verbands-gescopte SBK nur Einträge des eigenen
  # Verbands – globale (bundesweite) Einträge sind Admin-Sache (vgl. RefereeTags).
  class DocumentTypesController < ApplicationController
    include LicenseDocumentPresentation

    before_action :authorize_read!, only: :index
    before_action :authorize_manage!, only: %i[create update destroy]
    before_action :set_document_type, only: %i[update destroy]

    def index
      types = scoped_sbk? ? DocumentType.for_game_operations(sbk_go_ids) : DocumentType.all
      upload_counts = LicenseDocument.group(:document_type).count
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
      document_type.game_operation_id = sbk_go_ids.first if scoped_sbk? && document_type.game_operation_id.blank?
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless can_manage?(document_type)

      if document_type.save
        render json: document_type_json(document_type), status: :created
      else
        render json: { errors: document_type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      attrs = document_type_params
      # Gescopte SBK dürfen einen Eintrag nicht in einen anderen Verband verschieben.
      attrs = attrs.except(:game_operation_id) if scoped_sbk?
      @document_type.assign_attributes(attrs)
      @document_type.template.purge if params[:remove_template].present?

      if @document_type.save
        render json: document_type_json(@document_type)
      else
        render json: { errors: @document_type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      if in_use?(@document_type)
        return render json: { error: 'Dokumentart wird bereits verwendet (Uploads oder Liga-Konfiguration) und kann nicht gelöscht werden.' },
                      status: :unprocessable_entity
      end

      @document_type.destroy
      head :no_content
    end

    private

    def document_type_params
      params.require(:document_type).permit(:name, :description, :game_operation_id, :validity,
                                            :required_below_age, :template)
    end

    def set_document_type
      @document_type = DocumentType.find(params[:id])
      return if can_manage?(@document_type)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Dokumentart nicht gefunden' }, status: :not_found
    end

    def authorize_read!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_manage!
      authorize_read!
    end

    def scoped_sbk?
      ph = current_user.permission_hash
      ph[:admin].blank? && ph[:sbk].present? && ph[:sbk].exclude?(0)
    end

    def sbk_go_ids
      current_user.permission_hash[:sbk] || []
    end

    def can_manage?(document_type)
      return true unless scoped_sbk?

      document_type.game_operation_id.present? && sbk_go_ids.include?(document_type.game_operation_id)
    end

    def in_use?(document_type)
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
