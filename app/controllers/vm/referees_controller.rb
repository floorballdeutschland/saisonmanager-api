module Vm
  # Lesende Sicht des Vereinsmanagers auf die Schiedsrichter seines Vereins.
  #
  # Bewusst ein eigener Namensraum mit eigener, schmaler Antwort statt der
  # Admin-Detailansicht: Die liefert unter `full` Geburtsdatum und Anschrift,
  # und die braucht ein Verein nicht. Was der Verein sieht, steht vollständig
  # in referee_vm_json und referee_vm_detail_json.
  class RefereesController < ApplicationController
    before_action :authorize_vm!
    before_action :set_referee, only: %i[show games]

    # GET /api/v2/vm/referees
    #
    # Vereine sehen alles außer den Karriere-Beendeten. Der Import von 2025 hatte
    # praktisch dieselbe Grenze (Lizenz in einem der letzten Kursjahre), nur
    # wandert sie jetzt mit dem Saisonwechsel mit; deckungsgleich sind die beiden
    # Mengen nicht, weil hier das abgeleitete Ablaufdatum zählt und dort das
    # Kursjahr. Datensätze ohne Ablaufdatum bleiben sichtbar — ein vom Verein
    # neu angelegter Schiedsrichter hat noch keins.
    def index
      referees = visible_referees
                 .includes(:user, club: :state_association,
                                  referee_qualifications: :referee_qualification_type)
                 .order(:nachname, :vorname)

      render json: referees.map { |r| referee_vm_json(r) }
    end

    # GET /api/v2/vm/referees/:id
    def show
      render json: referee_vm_detail_json(@referee)
    end

    # GET /api/v2/vm/referees/:id/games
    #
    # Die gesamte Einsatzhistorie laut Spielbericht, auch aus der Zeit bei einem
    # früheren Verein. Gezählt wird wie überall über Referee#games.
    def games
      games = @referee.games
                      .includes(:home_team, :guest_team, game_day: :league)
                      .joins(:game_day)
                      .order('game_days.date DESC')

      render json: games.map { |g| game_summary(g) }
    end

    private

    def authorize_vm!
      return if current_user.permission_hash[:vm].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Dieselbe Menge wie die Liste: Was dort nicht steht, ist auch im Detail
    # nicht erreichbar. 404 statt 403, damit die Antwort nicht verrät, ob es
    # die ID bei einem anderen Verein gibt.
    def set_referee
      @referee = visible_referees.find_by(id: params[:id])
      render json: { error: 'Nicht gefunden' }, status: :not_found unless @referee
    end

    def visible_referees
      Referee.where(club_id: current_user.permission_hash[:vm]).not_career_ended
    end

    # E-Mail und Konto-Badge: Die Adresse meldet der Verein ohnehin selbst für
    # die Kursanmeldung, und das Badge zeigt ihm, wer sich schon anmelden kann.
    # Ein Konto anlegen kann er nicht, das macht die Schiedsrichterkommission
    # des Landesverbands. Telefonnummer und „kurzfristig mobil" bleiben außen
    # vor, die sind für die Ansetzung erhoben.
    def referee_vm_json(referee)
      {
        id: referee.id,
        lizenznummer: referee.lizenznummer,
        lizenznummer_display: referee.lizenznummer_display,
        vorname: referee.vorname,
        nachname: referee.nachname,
        email: referee.email,
        has_user: referee.user.present?,
        lizenzstufe: referee.lizenzstufe,
        gueltigkeit: referee.gueltigkeit&.strftime('%d.%m.%Y'),
        active: !referee.guest? && referee.gueltigkeit.present? && referee.gueltigkeit >= Date.today,
        club_name: referee.club&.name,
        landesverband: referee.landesverband,
        qualifications: referee.referee_qualifications.map do |q|
          {
            qualification_type_name: q.referee_qualification_type&.name,
            valid_until: q.valid_until&.strftime('%d.%m.%Y')
          }
        end
      }
    end

    # Bisher dieselben Felder wie die Listenzeile. Eine eigene Methode, damit
    # ein Feld für das Detail nicht versehentlich auch in der Liste landet.
    def referee_vm_detail_json(referee)
      referee_vm_json(referee)
    end

    # Gleiche Felder wie admin/referees#games ohne include_refs.
    def game_summary(game)
      {
        id: game.id,
        game_number: game.game_number,
        date: game.game_day.date,
        home_team: game.home_team&.name,
        guest_team: game.guest_team&.name,
        league: game.league&.name,
        league_id: game.league&.id,
        game_operation_slug: GameOperation.by_id[game.league&.game_operation_id]&.slug,
        season_id: game.game_day.league&.season_id,
        result: game.result_string
      }
    end
  end
end
