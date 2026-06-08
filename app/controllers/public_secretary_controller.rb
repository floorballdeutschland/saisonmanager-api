class PublicSecretaryController < ApplicationController
  skip_before_action :authenticate_user

  # GET /api/v2/public/secretary?token=XXX
  # Returns game day info + license lists for all games
  def show
    raw_token = params[:token]
    return render json: { message: 'Kein Token angegeben.' }, status: :bad_request unless raw_token.present?

    link = GameDaySecretaryLink.find_by_token(raw_token)
    return render json: { message: 'Dieser Link ist ungültig oder abgelaufen.' }, status: :gone if link.nil?

    game_day = link.game_day
    games = game_day.games.includes(:home_team, :guest_team).order(:start_time)

    render json: {
      game_day: {
        id: game_day.id,
        date: game_day.date,
        league: game_day.league&.name,
        arena: game_day.arena&.name,
        game_operation_slug: game_day.league&.game_operation&.slug
      },
      games: games.map { |g|
        {
          id: g.id,
          game_number: g.game_number,
          start_time: g.start_time,
          home_team: g.home_team&.name,
          guest_team: g.guest_team&.name,
          game_status: g.game_status
        }
      },
      license_lists: build_license_lists(games),
      expires_at: link.expires_at.iso8601,
      created_by: link.created_by&.fullname
    }
  end

  private

  def build_license_lists(games)
    team_ids = games.flat_map { |g| [g.home_team_id, g.guest_team_id] }.compact.uniq
    team_ids.each_with_object({}) do |team_id, hash|
      team = Team.find_by(id: team_id)
      next unless team

      players = Player.find_by_team_id(team_id)
      entries = players.filter_map do |player|
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
          approved_at: approved_entry&.dig('created_at'),
          valid_until: license['valid_until']
        }
      end.sort_by { |p| p[:name] }

      hash[team_id.to_s] = { team_name: team.name, players: entries }
    end
  end
end
