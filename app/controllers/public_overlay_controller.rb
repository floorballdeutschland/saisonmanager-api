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
# reicht nur bis zu EINER Liga -- dem Spieltag des Tokens und, in der
# Formkurve, den zuletzt beendeten Partien seiner beiden Mannschaften in
# derselben Liga -- und läuft von selbst ab. Wie weit genau, steht bei
# #build_overlay_schedule und bei #recent_games.
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

  # GET /api/v2/public/overlay/table?token=XXX
  #
  # Tabelle der Liga, zu der der Spieltag dieses Tokens gehört. Die Liga wird
  # ausschließlich aus dem Token abgeleitet; einen league_id-Parameter gibt es
  # bewusst nicht, sonst wäre aus dem spieltagsgebundenen Zugang ein
  # Generalschlüssel für jede Liga geworden.
  def table
    return if render_missing_league

    # Derselbe Cache-Eintrag wie in LeaguesController#table: gleiche Antwort,
    # gleicher Schlüssel, ein zweiter Weg dorthin und kein zweiter Bestand.
    body = Rails.cache.fetch("leagues/#{league.id}/table", expires_in: 5.minutes) do
      league.table
    end

    expires_in 30.seconds
    render json: league_frame.merge(table: body)
  end

  # GET /api/v2/public/overlay/scorer?token=XXX
  def scorer
    return if render_missing_league

    body = Rails.cache.fetch("leagues/#{league.id}/scorer", expires_in: 5.minutes) do
      league.scorer
    end

    expires_in 30.seconds
    render json: league_frame.merge(scorer: body)
  end

  # GET /api/v2/public/overlay/schedule?token=XXX
  #
  # Die Partien desselben Spieltags in der ganzen Liga, also auch die in anderen
  # Hallen. Grundlage für „nächste Spiele" und für den Hinweis, dass die Tabelle
  # noch nicht vollständig ist.
  def schedule
    return if render_missing_league

    expires_in 15.seconds
    render json: league_frame.merge(schedule: overlay_schedule)
  end

  # GET /api/v2/public/overlay/form?token=XXX
  #
  # Formkurve beider Mannschaften des aktiven Spiels: die letzten beendeten
  # Partien, neueste zuerst. Eigener Endpunkt und nicht Teil des Spielabrufs:
  # Der geht bei jedem Tor neu heraus, diese Liste aendert sich hoechstens, wenn
  # ein Spiel endet.
  def form
    return if render_missing_league

    game = resolve_game
    return render json: { message: 'Kein Spiel für diesen Spieltag.' }, status: :not_found if game.nil?

    expires_in 30.seconds
    render json: league_frame.merge(
      game_id: game.id,
      form: {
        home: team_form(game.home_team, game),
        guest: team_form(game.guest_team, game)
      }
    )
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

  def league
    @league ||= @link.game_day.league
  end

  # game_days.league_id ist nullable und ohne Fremdschlüssel. Ein Spieltag ohne
  # Liga hat weder Tabelle noch Spielplan; ohne diesen Riegel stürbe stattdessen
  # der erste Zugriff auf `league.id` im 500er.
  def render_missing_league
    return false if league

    render json: { message: 'Dieser Spieltag gehört zu keiner Liga.' }, status: :not_found
    true
  end

  # Der gemeinsame Rahmen aller drei ligaweiten Antworten. `running_games` steht
  # überall mit drin, damit ein Vollbild den Hinweis „Spiele laufen noch"
  # anzeigen kann, ohne dafür einen zweiten Abruf zu brauchen.
  #
  # Tabelle und Scorerliste zählen ausschließlich beendete Spiele
  # (League#evaluate_table_results und #evaluate_scorer prüfen `game.ended?`).
  # Solange parallel gespielt wird, sind sie also nicht falsch, sondern
  # unvollständig – und genau das muss auf Sendung erkennbar sein, sonst sieht
  # eine halbe Tabelle im Stream wie ein Fehler aus.
  def league_frame
    {
      league: {
        id: league.id,
        name: league.name,
        short_name: league.short_name,
        # Wie im Overlay-Abruf: Merkmale des Wettbewerbs statt der league_id,
        # die je Saison eine andere ist.
        league_class_id: league.league_class_id,
        female: league.female,
        # Muss in BEIDE Nutzlasten, sonst haengt das Erscheinungsbild eines
        # Vollbildes davon ab, welcher Abruf zuerst zurueckkommt.
        league_type: league.league_type
      },
      game_day: {
        id: @link.game_day.id,
        number: @link.game_day.number,
        date: @link.game_day.date
      },
      running_games: running_games
    }
  end

  # Alle Partien mit derselben Spieltagsnummer in dieser Liga, nicht nur die der
  # eigenen Halle: `League#games(number)` nimmt jeden GameDay dieser Nummer mit.
  # Das sind die parallel laufenden Spiele, um die es hier geht.
  def overlay_schedule
    @overlay_schedule ||= build_overlay_schedule
  end

  def build_overlay_schedule
    number = @link.game_day.number

    # `game_days.number` ist nullable, und GameDay hat keine einzige Validierung.
    # `League#games(nil)` bedeutet aber nicht "kein Spieltag", sondern JEDER: der
    # Zweig `game_day_number.present?` fällt durch auf `gd = game_days`. Ein
    # Spieltag ohne Nummer hätte damit die ganze Saison der Liga ins Vollbild
    # geholt und den Hinweis "Spiele laufen noch" für Partien ganz anderer Termine
    # ausgelöst. Ohne Nummer gibt es keinen ligaweiten Spieltag.
    return [] if number.blank?

    Rails.cache.fetch("leagues/#{league.id}/overlay_schedule/#{number}", expires_in: 30.seconds) do
      league.games(number).map(&:schedule_item)
    end
  end

  # HIER STAND EIN FILTER, UND WARUM ER WEG IST.
  #
  # Bis hierher wurden die Zwischenstände laufender Partien AUS ANDEREN HALLEN
  # aus dieser Liste entfernt (`strip_foreign_live_scores`), weil das Token die
  # Zehn-Minuten-Verzögerung nur für die Spiele SEINES Spieltags aufheben sollte.
  #
  # Diese Verzögerung richtet sich aber gegen API-Schlüssel ohne
  # Echtzeit-Freigabe (`ApplicationController#delay_live_data?`) und nicht gegen
  # das Publikum: Dieselben Zahlen stehen auf der öffentlichen Live-Seite, die
  # der Frontend-Schlüssel bedient. Der Filter hielt die Zwischenstände also
  # gerade dort zurück, wo sie am meisten helfen -- in der Spieltagsübersicht
  # einer Übertragung -- ohne sie irgendwo sonst zu verbergen. (Die Aussage
  # hängt daran, dass jener Schlüssel `realtime` gesetzt hat; auf Produktion
  # geprüft, im Code steht es nicht.)
  #
  # Die Grenze zieht der Endpunkt: `league` und `number` kommen allein aus dem
  # Token, ein `league_id`-Parameter existiert nicht. Und der Cache-Schlüssel
  # hängt an Liga und Spieltagsnummer, NICHT am Token -- alle Hallen desselben
  # Spieltags teilen ihn sich. Ein je Token unterschiedliches Ergebnis war darin
  # nur außerhalb des `fetch` korrekt zu bilden; ohne Filter stellt sich die
  # Frage für DIESEN Schlüssel nicht mehr. Für den je Mannschaft und Spiel
  # gebildeten Schlüssel der Formkurve gilt sie weiter, siehe #team_form.

  def running_games
    @running_games ||= overlay_schedule.select { |entry| running_entry?(entry) }.map do |entry|
      game_id = entry_value(entry, :game_id)
      {
        game_id: game_id,
        home_team_name: entry_value(entry, :home_team_name),
        guest_team_name: entry_value(entry, :guest_team_name),
        # Das eigene Spiel läuft auch, ist aber vollständig zu sehen. Ohne diese
        # Unterscheidung stünde der Hinweis „Spiele laufen noch" auch dann im
        # Bild, wenn nur die übertragene Partie läuft.
        own_game_day: own_game_ids.include?(game_id)
      }
    end
  end

  def own_game_ids
    @own_game_ids ||= @link.game_day.games.pluck(:id).to_set
  end

  # So viele Partien, wie eine Formkurve traegt. Fuenf ist die uebliche Laenge,
  # und mehr passt neben der zweiten Mannschaft nicht ins Bild.
  FORM_GAMES = 5

  def team_form(team, current_game)
    return nil if team.nil?

    {
      id: team.id,
      name: team.name,
      short_name: team.ticker_short_name,
      # Das übertragene Spiel gehört NICHT in seine eigene Formkurve: Sobald es
      # auf `ended` steht, wäre es sonst bei beiden Mannschaften Eintrag Nummer
      # eins -- und die Nachbetrachtung nach dem Schlusspfiff ist genau der
      # Moment, in dem dieses Bild eingeblendet wird. Deshalb steht seine id
      # auch im Cache-Schlüssel, sonst trüge ein Eintrag für ein anderes Spiel
      # desselben Spieltags die falsche Ausnahme.
      #
      # 30 Sekunden wie die übrigen ligaweiten Antworten und nicht 5 Minuten:
      # Nichts löscht diesen Schlüssel (`Game#flush_league_caches` kennt ihn
      # nicht), Tabelle und Spielplan im SELBEN Bild wären nach einem Spielende
      # also aktuell und die Formkurve daneben minutenlang alt.
      games: Rails.cache.fetch(
        "teams/#{team.id}/overlay_form/#{league.id}/#{current_game.id}",
        expires_in: 30.seconds
      ) do
        recent_games(team, current_game).map { |game| form_entry(game, team) }
      end
    }
  end

  # ACHTUNG, `game_days.date` ist eine Zeichenkette und keine Datumsspalte.
  # Absteigend sortiert wird also als TEXT. Fuer das ISO-Format (2026-09-19),
  # das die Anwendung schreibt, ist das chronologisch; ein Altbestand in einer
  # anderen Schreibweise waere es nicht -- `GameDay` prueft das Format nur bei
  # geaenderten Zeilen und begruendet das ausdruecklich mit vorhandenen
  # abweichenden Bestandszeilen. Sortiert wird trotzdem in der Datenbank, denn
  # erst das erlaubt das LIMIT; ohne das laedt eine Mannschaft ihre ganze
  # Historie, um fuenf Zeilen zu zeigen.
  #
  # NUR die Liga des Tokens. Das ist die Grenze, mit der dieser Zugang im ganzen
  # Controller begruendet ist (siehe Klassenkommentar): `Game.by_team_id` allein
  # ist ein reines `home_team_id OR guest_team_id` ohne Liga und Saison, und ein
  # Team behaelt seine id, wenn es ueber `cup_leagues` in einem Pokal
  # mitgemeldet wird -- ausgeliefert waeren damit auch Partien anderer Ligen.
  # Fachlich ist die Ligaform ohnehin das Gemeinte: In einer Bundesligapartie
  # sagt die Bundesligaform etwas, ein Pokalspiel gegen einen Regionalligisten
  # nicht. Zu Saisonbeginn ist die Kurve dafuer leer, und das Overlay benennt
  # diesen Zustand.
  #
  # Vorgeladen wird `game_day: :league` mit: `Game#result` greift bei
  # Verlaengerung und kampflosen Spielen auf die Liga zu, und
  # `ticker_short_name` faellt auf den Verein zurueck -- ohne diese Kette ergaben
  # fuenf Zeilen bis zu fuenfzehn Nachfragen.
  #
  # Der Ligafilter haelt zugleich ligalose Spieltage heraus, und das ist keine
  # Formsache: `game_days.league_id` ist nullable, und `Game#result` greift bei
  # kampflos gewerteten Spielen und bei Verlaengerung auf `league` zu
  # (`forfait_goals`, `period_titles`). Ohne diesen Riegel endete die ganze
  # Formkurve in `NoMethodError: undefined method forfait_goals for nil` --
  # nachgestellt. Der INNER JOIN auf die Liga sichert dasselbe ein zweites Mal
  # und traegt den Preload.
  def recent_games(team, current_game)
    Game.by_team_id(team.id)
        .where(ended: true)
        .where.not(id: current_game.id)
        .joins(game_day: :league)
        .where(game_days: { league_id: league.id })
        .includes(game_day: :league, home_team: :club, guest_team: :club)
        .order(Arel.sql('game_days.date DESC NULLS LAST, games.start_time DESC NULLS LAST'))
        .limit(FORM_GAMES)
  end

  def form_entry(game, team)
    heim = game.home_team_id == team.id
    gegner = heim ? game.guest_team : game.home_team
    result = game.result || {}
    eigene = heim ? result[:home_goals] : result[:guest_goals]
    fremde = heim ? result[:guest_goals] : result[:home_goals]

    ausgang = outcome_for(eigene, fremde)

    {
      game_id: game.id,
      date: game.game_day&.date,
      home: heim,
      opponent: gegner&.name,
      opponent_short: gegner&.ticker_short_name,
      # Ohne Wertung auch keine Tore. Das betrifft die beidseitige Wertung am
      # gruenen Tisch, die BEIDE Seiten negativ setzt (-3:-3): Wenn die Wertung
      # dazu schon keine Aussage macht, waere ein "-3:-3" im Bild die dazu
      # passende Falschaussage.
      goals: ausgang.nil? ? nil : eigene,
      opponent_goals: ausgang.nil? ? nil : fremde,
      # Verlaengerung und Penaltyschiessen gehoeren in eine Formkurve: Ein Sieg
      # n. V. ist ein anderer als ein regulaerer. Beides liegt in `result`
      # bereits fertig vor.
      overtime: result[:overtime] == true,
      # Aus dem Hash und nicht per zweitem `game.result_postfix`: `Game#result`
      # hat ihn dort schon abgelegt, und der Aufruf greift bei Verlaengerung auf
      # `league.period_titles` zu.
      postfix: result[:overtime] ? result.dig(:postfix, :short).presence : nil,
      # Aus Sicht DIESER Mannschaft. nil, wenn der Stand fehlt: `Game#result`
      # gibt nichts zurueck, solange ein Spiel nicht begonnen hat, und ein
      # beendetes Spiel ohne Ereignisse gibt es im Bestand auch. Ein Rueckfall
      # auf 0:0 waere hier eine erfundene Niederlage.
      outcome: ausgang,
      # Am gruenen Tisch entschieden. Gehoert ins Bild, weil ein 0:3 ohne diesen
      # Hinweis wie ein gespieltes Ergebnis aussieht.
      forfait: result[:forfait] == true
    }
  end

  def outcome_for(eigene, fremde)
    return nil unless eigene.is_a?(Integer) && fremde.is_a?(Integer)
    # Bei der beidseitigen Wertung setzt League#forfait_goals BEIDE Seiten
    # negativ (-3:-3). Das ist kein Unentschieden, sondern zwei Niederlagen, und
    # eine Formkurve kann das nicht darstellen -- also keine Aussage.
    return nil if eigene.negative? || fremde.negative?
    return 'win' if eigene > fremde
    return 'loss' if eigene < fremde

    'draw'
  end

  def entry_value(entry, key)
    entry.fetch(key) { entry[key.to_s] }
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
