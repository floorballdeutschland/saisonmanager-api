module Admin
  class StateAssociationChecklistItemsController < ApplicationController
    before_action :authorize_admin!
    before_action :set_state_association

    # POST /api/v2/admin/state_associations/:state_association_id/checklist_items
    def create
      item = @state_association.checklist_items.new(item_params)
      if item.save
        render json: item_hash(item), status: :created
      else
        render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/state_associations/:state_association_id/checklist_items/:id
    def update
      item = @state_association.checklist_items.find(params[:id])
      if item.update(item_params)
        render json: item_hash(item)
      else
        render json: { errors: item.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Frage nicht gefunden' }, status: :not_found
    end

    # DELETE /api/v2/admin/state_associations/:state_association_id/checklist_items/:id
    def destroy
      item = @state_association.checklist_items.find(params[:id])
      item.destroy
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Frage nicht gefunden' }, status: :not_found
    end

    private

    def set_state_association
      @state_association = StateAssociation.find(params[:state_association_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Landesverband nicht gefunden' }, status: :not_found
    end

    def item_params
      params.require(:checklist_item).permit(:question, :position)
    end

    def item_hash(item)
      { id: item.id, question: item.question, position: item.position }
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
