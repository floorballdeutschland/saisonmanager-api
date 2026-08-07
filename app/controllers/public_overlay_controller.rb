# Datenquelle der Livestream-Overlays. Angesprochen von den OBS-Browser-Quellen
# und vom Steuer-Dock, beide ohne Anmeldung, allein über das Spieltags-Token
# (GameDayOverlayLink).
#
# Aufbau wie PublicSecretaryController: `authenticate_user` übersprungen und
# bewusst OHNE `authenticate_public_request`. Letzteres verlangt Cookie oder
# X-Api-Key und würde einen reinen Token-Aufruf mit 401 abweisen.
#
# ZUR VERZÖGERUNG: Die zehn Minuten, die Inhaber eines API-Schlüssels ohne
# Echtzeit-Freigabe abwarten müssen, greifen hier nicht. Das ist kein
# vergessener Filter, sondern der Zweck dieses Zugangs. Die Prüfung in
# ApplicationController#delay_live_data? hängt an @authenticated_api_key, und
# die Variable wird hier nie gesetzt, weil authenticate_public_request nicht
# läuft. Der Unterschied zu einem Schlüssel mit Echtzeit-Freigabe: Dieses Token
# gilt nur für die Spiele eines Spieltags und läuft von selbst ab.
class PublicOverlayController < ApplicationController
  # Obergrenze für den Steuerzustand. Er wird bei jedem Abruf mit ausgeliefert,
  # also begrenzt diese Zahl zugleich den Datenverkehr, den ein weitergegebenes
  # Token erzeugen kann. Ein echter Zustand liegt bei wenigen hundert Byte.
  MAX_STATE_BYTES = 16_384

  skip_before_action :authenticate_user
  before_action :load_link

  # GET /api/v2/public/overlay/live?token=XXX&game_id=123&v=<updated_at>
  #
  # Ein Endpunkt für Steuerzustand UND Spieldaten: Der Zustand muss im
  # Sekundentakt nachziehen, die Spieldaten sind deutlich größer. Schickt der
  # Client in `v` den Stand mit, den er schon hat, bleibt der Spielblock weg und
  # die Antwort ist ein paar hundert Byte groß.
  def live
    game = resolve_game
    return render json: { message: 'Kein Spiel für diesen Spieltag.' }, status: :not_found if game.nil?

    body = {
      state: @link.state || {},
      state_updated_at: @link.state_updated_at&.to_f,
      game_id: game.id,
      game_version: game.updated_at.to_f,
      server_time: (Time.current.to_f * 1000).round
    }

    body[:game] = overlay_payload(game) unless params[:v].to_s == game.updated_at.to_f.to_s

    render json: body
  end

  # GET /api/v2/public/overlay/game_day?token=XXX
  #
  # Rahmendaten für das Dock: Welche Spiele gehören zum Spieltag, damit sich
  # zwischen ihnen umschalten lässt, ohne ein neues Token zu holen.
  def game_day
    gd = @link.game_day
    games = gd.games.includes(:home_team, :guest_team).order(:start_time)

    render json: {
      game_day: {
        id: gd.id,
        date: gd.date,
        number: gd.number,
        league: gd.league&.name,
        league_id: gd.league&.id,
        arena: gd.arena&.name
      },
      games: games.map do |g|
        {
          id: g.id,
          game_number: g.game_number,
          start_time: g.start_time,
          home_team: g.home_team&.name,
          guest_team: g.guest_team&.name,
          started: g.started,
          ended: g.ended,
          game_status: g.game_status
        }
      end,
      expires_at: @link.expires_at.iso8601
    }
  end

  # POST /api/v2/public/overlay/state?token=XXX
  #
  # Das Dock schreibt den kompletten Zustand, nicht einzelne Felder: Die
  # Einblendungen hängen voneinander ab (eine sichtbare Bauchbinde und ein
  # laufendes Vollbild schließen sich aus), ein Teilupdate müsste diese Regeln
  # doppelt kennen.
  #
  # CSRF greift hier nicht: ApplicationController#verified_request? lässt
  # Anfragen ohne angemeldeten Nutzer durch, wie beim Spielsekretariat.
  def set_state
    incoming = params[:state]
    return render json: { message: 'Kein Zustand übergeben.' }, status: :bad_request if incoming.blank?

    # Muss ein Objekt sein. Ein Text oder eine Liste käme sonst so in die
    # JSONB-Spalte, und der nächste Lesezugriff (`state.dig`) stürbe daran: Ein
    # einziger krummer Schreibvorgang legte damit alle Browser-Quellen und Docks
    # dieses Spieltags lahm, bis jemand den Zustand überschreibt.
    unless incoming.respond_to?(:to_unsafe_h)
      return render json: { message: 'Der Steuerzustand muss ein Objekt sein.' }, status: :bad_request
    end

    state = incoming.to_unsafe_h

    # Der Zustand geht bei JEDEM Abruf wieder mit hinaus, auch wenn die
    # Spieldaten wegbleiben. Ohne Obergrenze könnte ein weitergegebenes Token
    # damit beliebig Datenverkehr erzeugen. Ein echter Steuerzustand liegt bei
    # wenigen hundert Byte.
    if state.to_json.bytesize > MAX_STATE_BYTES
      return render json: { message: 'Der Steuerzustand ist zu groß.' }, status: :payload_too_large
    end

    # Zwei gleichzeitig geöffnete Docks würden sich sonst gegenseitig
    # überschreiben. Wer auf einem älteren Stand schreibt, wird abgewiesen und
    # holt sich erst den aktuellen.
    if stale_write?
      return render json: { message: 'Der Steuerzustand wurde zwischenzeitlich geändert.',
                            state: @link.state, state_updated_at: @link.state_updated_at&.to_f },
                    status: :conflict
    end

    @link.update!(state: state, state_updated_at: Time.current)

    render json: { state: @link.state, state_updated_at: @link.state_updated_at.to_f }
  end

  private

  def load_link
    raw_token = params[:token]
    return render json: { message: 'Kein Token angegeben.' }, status: :bad_request if raw_token.blank?

    @link = GameDayOverlayLink.find_by_token(raw_token)
    return if @link

    render json: { message: 'Dieser Link ist ungültig oder abgelaufen.' }, status: :gone
  end

  # Ohne game_id das Spiel, das das Dock zuletzt gewählt hat; ohne diese Wahl
  # das erste des Spieltags. So zeigt eine frisch eingerichtete Browser-Quelle
  # sofort etwas an, auch bevor das Dock einmal geöffnet wurde.
  def resolve_game
    scope = @link.game_day.games
    # `state` ist zwar seit der Prüfung in set_state immer ein Objekt, ein
    # Altbestand aus der Zeit davor könnte aber noch etwas anderes enthalten.
    stored = @link.state.is_a?(Hash) ? @link.state['active_game_id'] : nil
    requested = params[:game_id].presence || stored

    (requested.present? && scope.find_by(id: requested)) || scope.order(:start_time).first
  end

  def overlay_payload(game)
    # Wie games#show auf updated_at geschlüsselt: Jeder Eintrag im Spielbericht
    # fasst das Spiel an, der Eintrag ist also sofort ungültig. Der
    # Steuerzustand gehört NICHT hier hinein, er liegt am Link und ändert sich,
    # ohne dass game.updated_at wandert.
    Rails.cache.fetch("games/#{game.id}/overlay/#{game.updated_at.to_f}", expires_in: 1.minute) do
      OverlayPayload.new(game).as_json
    end
  end

  # `to_s` vor `to_f`: Kommt hier ein Objekt oder eine Liste an, hätte `to_f`
  # keine Entsprechung und die Anfrage endete in einem 500 statt in einer
  # verständlichen Antwort.
  def stale_write?
    seen = params[:state_updated_at]
    return false if seen.blank? || @link.state_updated_at.blank?

    seen.to_s.to_f < @link.state_updated_at.to_f
  end
end
