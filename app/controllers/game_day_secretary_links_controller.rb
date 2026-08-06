class GameDaySecretaryLinksController < ApplicationController
  include GameDayLinkAuthorization

  before_action :authenticate_user
  before_action :load_game_day
  before_action :authorize_vm_or_tm!

  # POST /api/v2/user/game_days/:game_day_id/secretary_link
  def create
    link, raw_token = GameDaySecretaryLink.generate!(game_day: @game_day, created_by: current_user)

    render json: {
      url: "#{FrontendUrl.base}/spielsekretariat?token=#{raw_token}",
      token: raw_token,
      expires_at: link.expires_at.iso8601,
      created_by: current_user.fullname,
      game_day_id: @game_day.id
    }, status: :created
  end

  # GET /api/v2/user/game_days/:game_day_id/secretary_link
  def show
    link = GameDaySecretaryLink.active.find_by(game_day: @game_day)
    if link
      render json: {
        expires_at: link.expires_at.iso8601,
        created_by: link.created_by&.fullname
      }
    else
      render json: { active: false }
    end
  end
end
