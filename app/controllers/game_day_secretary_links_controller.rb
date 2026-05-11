class GameDaySecretaryLinksController < ApplicationController
  before_action :authenticate_user
  before_action :load_game_day
  before_action :authorize_vm_or_tm!

  # POST /api/v2/user/game_days/:game_day_id/secretary_link
  def create
    link, raw_token = GameDaySecretaryLink.generate!(game_day: @game_day, created_by: current_user)

    frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
    first_game = @game_day.games.order(:start_time).first

    render json: {
      url: "#{frontend_base}/spielsekretariat/#{first_game&.id}?token=#{raw_token}",
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

  private

  def load_game_day
    @game_day = GameDay.find(params[:game_day_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spieltag nicht gefunden.' }, status: :not_found
  end

  def authorize_vm_or_tm!
    ph = current_user.permission_hash
    go_id = @game_day.league.game_operation_id
    return if ph[:admin].present?
    return if ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id))

    game_ids = @game_day.games.pluck(:home_team_id, :guest_team_id).flatten.compact
    club_id = @game_day.club_id

    vm_allowed = ph[:vm].present? && (ph[:vm].include?(club_id) ||
                   @game_day.games.any? { |g|
                     ph[:vm].intersection([g.home_team&.club_id, g.guest_team&.club_id].compact).present?
                   })
    tm_allowed = ph[:tm].present? && ph[:tm].intersection(game_ids).present?

    return if vm_allowed || tm_allowed

    render json: { error: 'Nicht berechtigt.' }, status: :forbidden
  end
end
