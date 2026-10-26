module Admin
  # Pflege der Regeln für den Lizenzvorschlag (api#861). Bundesweit gleich und
  # nur durch Admin, wie der Lizenzstufen-Katalog.
  class RefereeLicenseSuggestionRulesController < ApplicationController
    before_action :authorize_admin!
    before_action :set_rule, only: %i[update destroy]

    # GET /api/v2/admin/referee_license_suggestion_rules
    # Neben den Regeln die Auswahllisten der Maske: Kurstypen und die
    # Altersklassen, die in Ligen vorkommen. Eine neu auftauchende Altersklasse
    # steht damit sichtbar unangehakt in der Maske, statt still nicht zu zählen.
    def index
      render json: {
        rules: RefereeLicenseSuggestionRule.ordered.includes(:referee_license_level).map { |r| rule_json(r) },
        course_types: RefereeCourse::COURSE_TYPES,
        field_sizes: RefereeLicenseSuggestionRule::FIELD_SIZES,
        age_groups: League.unscoped.where.not(age_group: [nil, '']).distinct.order(:age_group).pluck(:age_group)
      }
    end

    # POST /api/v2/admin/referee_license_suggestion_rules
    def create
      rule = RefereeLicenseSuggestionRule.new(rule_params)
      if rule.save
        render json: rule_json(rule), status: :created
      else
        render json: { errors: rule.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_license_suggestion_rules/:id
    def update
      if @rule.update(rule_params)
        render json: rule_json(@rule)
      else
        render json: { errors: @rule.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referee_license_suggestion_rules/:id
    def destroy
      @rule.destroy
      head :no_content
    end

    private

    def authorize_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def set_rule
      @rule = RefereeLicenseSuggestionRule.find_by(id: params[:id])
      render json: { error: 'Regel nicht gefunden' }, status: :not_found if @rule.nil?
    end

    def rule_params
      params.require(:rule).permit(:course_type, :referee_license_level_id, :position, :min_games, :field_size,
                                   age_groups: [])
    end

    def rule_json(rule)
      {
        id: rule.id,
        course_type: rule.course_type,
        referee_license_level_id: rule.referee_license_level_id,
        lizenzstufe: rule.referee_license_level&.name,
        position: rule.position,
        min_games: rule.min_games,
        field_size: rule.field_size,
        age_groups: rule.age_groups
      }
    end
  end
end
