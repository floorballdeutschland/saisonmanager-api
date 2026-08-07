class RefereesController < ApplicationController
  skip_before_action :authenticate_user, only: %i[show search]
  before_action :authenticate_public_request, only: %i[show search]

  # GET /api/v2/user/referees/:id
  # Returns public license info by Lizenznummer (no personal data)
  #
  # Schiedsrichter mit beendeter Karriere bleiben hier außen vor und
  # antworten wie eine unbekannte Nummer. Ihre Datensätze existieren als
  # Register alter Lizenznummern; geprüft werden Reaktivierungen intern durch
  # FD, nicht über den öffentlichen Lizenzcheck. Ein „gab es mal"-Signal
  # gehört nicht auf eine per API-Key erreichbare Fläche.
  #
  # Datensätze ohne Ablaufdatum antworten dagegen weiter (mit leerer
  # Gültigkeit): Sie sind kein beendeter Fall, sondern einer ohne Nachweis.
  def show
    referee = Referee.includes(club: :state_association, referee_qualifications: :referee_qualification_type)
                     .not_career_ended
                     .find_by(lizenznummer: params[:id].to_i)

    if referee
      render json: {
        lizenznummer: referee.lizenznummer,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        landesverband: referee.landesverband,
        verein: referee.club&.name,
        qualifications: referee.referee_qualifications.map do |q|
          {
            qualification_type_name: q.referee_qualification_type&.name,
            valid_until: q.valid_until&.strftime('%d.%m.%Y')
          }
        end
      }
    else
      render json: { error: 'Lizenz nicht gefunden' }, status: :not_found
    end
  end

  # GET /api/v2/referees/search?q=...
  # Autocomplete: sucht nach Name oder Lizenznummer, gibt max. 10 Treffer zurück.
  # Bewusst per X-Api-Key erreichbar (kein Cookie-Zwang): wird vom öffentlichen
  # Lizenzcheck (/lizenzcheck) und vom Spielbericht mit Kampfgericht-Token
  # genutzt (#64).
  def search
    q = params[:q].to_s.strip
    return render json: [] if q.empty?

    # Query auf sinnvolle Länge begrenzen, bevor nach Tokens gesplittet wird
    q = q[0, 100]

    # Ohne den Fenster-Filter würden hier Name, Stufe und Landesverband von
    # Personen ausgeliefert, die seit Jahren nicht mehr pfeifen (Nachimport der
    # Karriere-Beendeten). Die Autocomplete ist per X-Api-Key erreichbar.
    referees = Referee.not_career_ended.search(q).order(:nachname, :vorname).limit(10)

    render json: referees.includes(club: :state_association).map { |r|
      {
        lizenznummer: r.lizenznummer,
        vorname:      r.vorname,
        nachname:     r.nachname,
        lizenzstufe:  r.lizenzstufe,
        landesverband: r.landesverband
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
