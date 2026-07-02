module Admin
  # Frei definierbare Schiedsrichter-Tags (z. B. „Spitzenschiri", „Finalspiel-
  # tauglich"), mit denen Ansetzer ihren Bestand kategorisieren und in der
  # Ansetzung vorfiltern. Der Katalog ist pro Spielbetrieb gescopt: ein
  # LV-Ansetzer pflegt seine eigenen Tags, globale Tags (ohne Spielbetrieb)
  # sind allen sichtbar und nur von Admin/FD verwaltbar.
  class RefereeTagsController < ApplicationController
    include RefereeScoping

    before_action :authorize_tag_read!, only: %i[index]
    before_action :authorize_tag_manage!, only: %i[create update destroy]
    before_action :set_tag, only: %i[update destroy]

    # GET /api/v2/admin/referee_tags
    def index
      tags = visible_tags(RefereeTag.all).order(:name)
      counts = RefereeTagging.group(:referee_tag_id).count
      render json: tags.map { |t| tag_json(t, usage_count: counts[t.id] || 0) }
    end

    # POST /api/v2/admin/referee_tags
    def create
      tag = RefereeTag.new(tag_params)
      tag.game_operation_id = default_game_operation_id if scoped_role? && tag.game_operation_id.blank?

      return forbidden_response unless can_manage_tag?(tag)

      if tag.save
        render json: tag_json(tag), status: :created
      else
        render json: { errors: tag.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_tags/:id
    def update
      return forbidden_response unless can_manage_tag?(@tag)

      @tag.assign_attributes(tag_params)
      # Ein gescopter Ansetzer darf einen Tag nicht aus seinem Verband heraus-
      # oder global schieben.
      @tag.game_operation_id = @tag.game_operation_id_was if scoped_role?

      if @tag.save
        render json: tag_json(@tag)
      else
        render json: { errors: @tag.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referee_tags/:id
    def destroy
      return forbidden_response unless can_manage_tag?(@tag)

      # Zuordnungen werden über dependent: :destroy mit entfernt – ein Tag darf
      # bewusst auch gelöscht werden, wenn er noch verwendet wird.
      @tag.destroy
      head :no_content
    end

    private

    def set_tag
      @tag = RefereeTag.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Tag nicht gefunden' }, status: :not_found
    end

    def tag_params
      params.require(:referee_tag).permit(:name, :color, :game_operation_id)
    end

    def authorize_tag_read!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?

      forbidden_response
    end

    def authorize_tag_manage!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?

      forbidden_response
    end

    def forbidden_response
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Sichtbarer Tag-Bestand: nur der Admin (unscoped) sieht alles inkl. globaler
    # Tags fremder Verbände. Jeder verbandsgebundene Nutzer – auch FD – sieht nur
    # die eigenen Verbands-Tags plus die globalen (game_operation_id IS NULL).
    def visible_tags(relation)
      return relation unless scoped_role?

      relation.for_game_operations(tag_scope_go_ids)
    end

    # Eigene Verbands-Tags darf ein gescopter Nutzer verwalten; globale Tags
    # (game_operation_id NULL) bleiben dem Admin vorbehalten.
    def can_manage_tag?(tag)
      return true unless scoped_role?

      tag.game_operation_id.present? && tag_scope_go_ids.include?(tag.game_operation_id)
    end

    # True, wenn der Nutzer an einen konkreten Verband gebunden ist (LV oder FD).
    # Nur der Admin (bzw. ein explizit auf Spielbetrieb 0 gesetzter Nutzer) ist
    # unscoped und sieht/verwaltet den globalen Tag-Bestand.
    def scoped_role?
      return false if current_user.permission_hash[:admin].present?

      tag_scope_go_ids.present?
    end

    def default_game_operation_id
      tag_scope_go_ids.first
    end

    def tag_json(tag, usage_count: tag.referee_taggings.count)
      {
        id: tag.id,
        name: tag.name,
        color: tag.color,
        game_operation_id: tag.game_operation_id,
        usage_count: usage_count
      }
    end
  end
end
