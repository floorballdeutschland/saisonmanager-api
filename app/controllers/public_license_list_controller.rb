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

    # Nach Nachnamen, siehe Player#license_list_sort_key. Vor dem Aufbau
    # sortieren: Der Eintrag traegt nur den zusammengesetzten Anzeigenamen.
    players = Player.find_by_team_id(team.id).sort_by(&:license_list_sort_key)
    players.filter_map do |player|
      license = player.extr_license
      next unless license

      # `to_s` ist Pflicht, nicht Zierde: Ein Verlaufseintrag ohne `created_at`
      # laesst `max_by` mit „comparison of NilClass with String failed" platzen,
      # und das ist eine 500 auf dem oeffentlichen Lizenzlink, kurz vor Anwurf.
      # Solche Eintraege gibt es im Altbestand; im Sekretariats-Controller ist
      # derselbe Absturz deshalb bereits so abgefangen.
      last_status = license['history']&.max_by { |h| h['created_at'].to_s }
      next unless last_status

      last_status_id = last_status['license_status_id'].to_i
      next unless [License::APPROVED, License::REQUESTED].include?(last_status_id)

      # `to_i` und die Konstante statt der nackten 1: Liegt der Status als String
      # „1" im JSONB — im Altbestand beides anzutreffen —, bliebe `approved_at`
      # sonst leer, und leer ist ausgerechnet die Spalte „Genehmigt am", an der
      # am Kampfgericht die Spielberechtigung abgelesen wird.
      approved_entry = license['history']&.select do |h|
        h['license_status_id'].to_i == License::APPROVED
      end&.last

      {
        name: "#{player.first_name} #{player.last_name}",
        birthdate: player.birthdate,
        license_status: License::NAMES[last_status_id],
        approved_at: approved_entry&.dig('created_at'),
        valid_until: license['valid_until']
      }
    end
  end
end
