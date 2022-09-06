class PlayersController < ApplicationController
  before_action :set_player, only: %i[show update destroy]

  # GET /players
  def index
    @players = Player.all.order(:last_name).order(:first_name).where("last_name != '' AND first_name != ''").order(:birthdate)
  end

  # GET /players/1
  def show; end

  def admin_players_index
    if current_user
      result = Player.admin_user_players(current_user, params[:club_id])

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def user_get_nations
    result = []

    Setting.current.nations.each do |k, v|
      item = {
        id: k,
        name: v['name'],
        eu: v['eu'],
        eu: v['short_name']
      }

      result << item
    end

    render json: result
  end

  def admin_player
    if current_user
      result = Player.find(params[:id])

      render json: result.full_hash
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def request_license
    # hole spieler
    player = Player.find(params[:id])
    team = Team.find(params[:team_id])
    league = team.league

    ph = current_user.permission_hash
    # prüfe ob user lizenz für team beantragen darf
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end

    # TODO:
    # prüfe ob eine lizenz für das team bereits vorliegt

    if allowed
      # füge lizenz zu lizenzhash hinzu
      new_license = {
        id: Digest::UUID.uuid_v4,
        team_id: team.id,
        league_class_id: league.league_class_id,
        male: !league.female,
        history: [{
          license_status_id: License::REQUESTED,
          created_by: current_user.id,
          created_at: Time.now
        }]
      }
      player.licenses << new_license

      if player.save
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden
    end
  end

  def withdraw_license_request
    # hole spieler
    player = Player.find(params[:id])

    found_license = nil
    player.licenses.map! do |license|
      if license['_id'].present?
        license['id'] = license['_id']
        license['_id'] = nil
      end
      if license['id'] == params[:license_id]
        found_license = license

        license['history'] << {
          license_status_id: License::WITHDRAWN,
          created_by: current_user.id,
          created_at: Time.now
        }
      end

      license
    end

    # prüfe ob user lizenz für team beantragen darf
    team = Team.find(found_license['team_id'])

    ph = current_user.permission_hash
    allowed = if ph[:admin].present? || ph[:sbk].present?
                true
              elsif ph[:vm].present?
                ph[:vm].include?(team.club_id) || ph[:vm].intersection(team.syndicate_clubs).present?
              elsif ph[:tm].present?
                ph[:tm].include?(team.id)
              end

    if allowed
      if player.save
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden
    end
  end

  private

  def set_player
    @player = Player.find(params[:id])
  end
end
