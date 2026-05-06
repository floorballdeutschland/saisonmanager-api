class PublicLicenseListController < ApplicationController
  skip_before_action :authenticate_user

  def show
    payload = Rails.application.message_verifier('license_list').verified(params[:token])

    if payload.nil?
      return render json: { message: 'Dieser Link ist ungültig oder abgelaufen.' }, status: :gone
    end

    game = Game.find(payload[:game_id])

    render json: {
      game: {
        game_number: game.game_number,
        date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        league_name: game.game_day.league.name
      },
      home_team_licenses: team_license_list(game.home_team),
      guest_team_licenses: team_license_list(game.guest_team),
      expires_at: payload[:expires_at]
    }
  rescue ActiveRecord::RecordNotFound
    render json: { message: 'Spiel nicht gefunden.' }, status: :not_found
  end

  private

  def team_license_list(team)
    return [] unless team

    players = Player.find_by_team_id(team.id)
    players.filter_map do |player|
      license = player.extr_license
      next unless license

      last_status = license['history']&.max_by { |h| h['created_at'] }
      next unless last_status

      last_status_id = last_status['license_status_id'].to_i
      next unless [License::APPROVED, License::REQUESTED].include?(last_status_id)

      approved_entry = license['history']&.select { |h| h['license_status_id'] == 1 }&.last

      {
        name: "#{player.first_name} #{player.last_name}",
        birthdate: player.birthdate,
        license_status: License::NAMES[last_status_id],
        approved_at: approved_entry&.dig('created_at')
      }
    end.sort_by { |p| p[:name] }
  end
end
