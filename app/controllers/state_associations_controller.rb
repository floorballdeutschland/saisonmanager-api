class StateAssociationsController < ApplicationController
  skip_before_action :authenticate_user
  before_action :authenticate_public_request

  # GET /api/v2/state_associations
  def index
    render json: StateAssociation.with_attached_logo.order(:name).map(&:short_hash)
  end
end
