class RefereesController < ApplicationController
  skip_before_action :authenticate_user, only: %i[show search]
  before_action :authenticate_public_request, only: %i[show search]

  # GET /api/v2/user/referees/:id
  # Returns public license info by Lizenznummer (no personal data)
  def show
    referee = Referee.find_by(lizenznummer: params[:id].to_i)

    if referee
      render json: {
        lizenznummer: referee.lizenznummer,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        zusatzqualifikation: referee.zusatzqualifikation,
        gueltigkeit_z: referee.gueltigkeit_z&.strftime('%d.%m.%Y'),
        verein: referee.verein
      }
    else
      render json: { error: 'Lizenz nicht gefunden' }, status: :not_found
    end
  end

  # GET /api/v2/referees/search?q=...
  # Autocomplete: sucht nach Name oder Lizenznummer, gibt max. 10 Treffer zurück
  def search
    q = params[:q].to_s.strip
    return render json: [] if q.empty?

    # Query auf sinnvolle Länge begrenzen, bevor nach Tokens gesplittet wird
    q = q[0, 100]

    referees = Referee.search(q).order(:nachname, :vorname).limit(10)

    render json: referees.map { |r|
      {
        lizenznummer:     r.lizenznummer,
        vorname:          r.vorname,
        nachname:         r.nachname,
        lizenzstufe:      r.lizenzstufe,
        verein:           r.verein
      }
    }
  end

  # GET /api/v2/referees/:id/games
  def games
    referee = Referee.find_by(lizenznummer: params[:id].to_i)
    return render json: { error: 'Lizenz nicht gefunden' }, status: :not_found unless referee

    season_id = params[:season_id]
    games = referee.games(season_id: season_id)
                   .includes(:league, :home_team, :guest_team)
                   .order(date: :desc)

    render json: games.map { |g| game_summary(g) }
  end

  private

  def game_summary(game)
    {
      id: game.id,
      game_number: game.game_number,
      date: game.date,
      home_team: game.home_team&.name,
      guest_team: game.guest_team&.name,
      league: game.league&.name,
      season_id: game.season_id,
      result: game.result_string
    }
  end
end
