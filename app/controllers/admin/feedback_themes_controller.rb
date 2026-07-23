module Admin
  # Pflege der Themen-Taxonomie für die Auswertung der Feedback-Freitexte (#182).
  # Eine flache, FD-weite Liste; verwaltbar von Admin und den globalen FD-Rollen
  # (gleiche Sichtbarkeit wie das Feedback selbst).
  class FeedbackThemesController < ApplicationController
    include FeedbackVisibility

    before_action :authorize_feedback_access!
    before_action :set_theme, only: %i[update destroy]

    # GET /api/v2/admin/feedback_themes
    def index
      counts = FeedbackThemeTagging.group(:feedback_theme_id).count
      render json: FeedbackTheme.ordered.map { |theme| theme_json(theme, usage_count: counts[theme.id] || 0) }
    end

    # POST /api/v2/admin/feedback_themes
    def create
      theme = FeedbackTheme.new(theme_params)
      if theme.save
        render json: theme_json(theme), status: :created
      else
        render json: { errors: theme.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/feedback_themes/:id
    def update
      if @theme.update(theme_params)
        render json: theme_json(@theme)
      else
        render json: { errors: @theme.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/feedback_themes/:id
    def destroy
      # Zuordnungen werden über dependent: :destroy mit entfernt.
      @theme.destroy
      head :no_content
    end

    private

    def set_theme
      @theme = FeedbackTheme.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Thema nicht gefunden' }, status: :not_found
    end

    def theme_params
      params.require(:feedback_theme).permit(:name, :color, :position)
    end

    def theme_json(theme, usage_count: theme.feedback_theme_taggings.count)
      {
        id: theme.id,
        name: theme.name,
        color: theme.color,
        position: theme.position,
        usage_count: usage_count
      }
    end
  end
end
