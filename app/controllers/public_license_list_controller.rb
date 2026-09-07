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
      # Die Liga des SPIELS entscheidet ueber die Sperren, nicht die Stammliga
      # der Mannschaft: Ein Pokalspiel laeuft in der Pokalliga, und eine im
      # Ligaspielbetrieb gesperrte Lizenz gilt dort weiter.
      home_team_licenses: team_license_list(game.home_team, game.game_day.league),
      guest_team_licenses: team_license_list(game.guest_team, game.game_day.league),
      expires_at: payload[:expires_at]
    }
  rescue ActiveRecord::RecordNotFound
    render json: { message: 'Spiel nicht gefunden.' }, status: :not_found
  end

  private

  def team_license_list(team, league)
    return [] unless team

    # Nach Nachnamen, siehe Player#license_list_sort_key. Vor dem Aufbau
    # sortieren: Der Eintrag traegt nur den zusammengesetzten Anzeigenamen.
    players = Player.find_by_team_id(team.id).sort_by(&:license_list_sort_key)
    suspensions = PlayerSuspension.active_by_player(players.map(&:id))

    players.filter_map do |player|
      license = player.extr_license
      next unless license

      # Der Status OHNE Sperre ist die Grundlage, die Sperre kommt getrennt
      # dazu (#605): Eine Wettbewerbs- oder Ligasperre steht gar nicht in der
      # Lizenzhistorie, weil dieselbe Lizenz in der Liga gesperrt und im Pokal
      # erteilt sein kann. Wer nur die History liest, sieht sie nicht -- am
      # Spieltisch stand der Gesperrte deshalb als spielberechtigt.
      #
      # LicenseEffectiveStatus.base_entry vergleicht `created_at.to_s`: Ein
      # Verlaufseintrag ohne Zeitstempel liess `max_by` mit „comparison of
      # NilClass with String failed" platzen, und das ist eine 500 auf dem
      # oeffentlichen Lizenzlink, kurz vor Anwurf.
      base_status = LicenseEffectiveStatus.base_entry(license)
      next unless base_status

      base_status_id = base_status['license_status_id'].to_i
      next unless [License::APPROVED, License::REQUESTED].include?(base_status_id)

      suspension = Array(suspensions[player.id]).find { |s| s.covers_license_in?(league, team) }

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
        license_status: License::NAMES[suspension ? License::SUSPENDED : base_status_id],
        # Nur der Geltungsbereich, nicht die Begruendung -- wie im Kaderdialog
        # des Spielsekretariats. Warum jemand gesperrt ist, bleibt der
        # Verbandsansicht vorbehalten.
        suspension_scope: suspension&.scope_summary,
        approved_at: approved_entry&.dig('created_at'),
        valid_until: license['valid_until']
      }
    end
  end
end
