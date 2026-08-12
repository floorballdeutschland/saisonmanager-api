# Was heute übertragen wird.
#
# `games.live_stream_link` und `games.vod_link` werden im Spielbericht in
# Schritt 1 erfasst, standen bisher aber nur am einzelnen Spiel. Wer wissen
# wollte, was gerade läuft, musste die Ligen einzeln durchgehen.
#
# HIER GILT DIE NORMALE REGEL, NICHT DIE OVERLAY-AUSNAHME. Der Abruf verhält
# sich wie jeder andere öffentliche: `authenticate_public_request`, und die
# Zwischenstände laufender Partien gehen durch `delay_live_scores`, dieselbe
# Verzögerungslogik, die die Spielplan-Abrufe schon benutzen. Angemeldete
# Nutzer und die Saisonmanager-Website sehen Live-Stände, ein fremder Schlüssel
# ohne Echtzeit-Freigabe erst nach zehn Minuten.
#
# Der Unterschied zum PublicOverlayController ist Absicht: Dessen Token bedient
# genau eine Übertragung und gilt nur für die Spiele eines Spieltags. Ein
# tagesweiter Abruf ohne Verzögerung wäre über die Hintertür genau die Lücke,
# die zuletzt an zwei anderen Abrufen geschlossen wurde.
class LiveStreamsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[index]
  before_action :authenticate_public_request, only: %i[index]

  # GET /api/v2/live_streams
  #
  # Die Spiele des Tages mit hinterlegtem Stream-Link, nach Anwurf sortiert:
  # laufende zuerst mit Abschnitt und Zwischenstand, dann die anstehenden,
  # darunter die beendeten mit Endstand und Aufzeichnung.
  def index
    date = today

    entries = Rails.cache.fetch("live_streams/#{date}", expires_in: 30.seconds) do
      build_entries(date)
    end

    # `private` (Vorgabe von expires_in), weil die Antwort je nach Zugang
    # unterschiedlich ausfällt: Cookie-Session und Echtzeit-Schlüssel sehen
    # Zwischenstände, ein gewöhnlicher Schlüssel nicht. Ein gemeinsamer Cache
    # davor würde die eine Fassung an den anderen Abrufer ausliefern.
    expires_in 30.seconds
    render json: { date: date.to_s, games: delay_live_scores(entries) }
  end

  private

  # Reihenfolge der Blöcke, wie sie im Bild stehen sollen.
  STATUS_ORDER = { 'running' => 0, 'upcoming' => 1, 'ended' => 2 }.freeze

  # `game_days.date` ist ein lokales Datum ohne Zeitzone: der Tag, an dem in der
  # Halle gespielt wird. Die Anwendung läuft in UTC (`config.time_zone` ist
  # nicht gesetzt), abends nach 22 Uhr wäre „heute" dort noch der Vortag und die
  # Seite fiele an genau den Abenden leer aus, an denen übertragen wird.
  # Deshalb derselbe Kalender, mit dem RefereeFeedbackWindow rechnet; eine
  # zweite Definition von „heute" ist genau die Stelle, an der beide auseinander
  # laufen.
  def today
    RefereeFeedbackWindow.today
  end

  def build_entries(date)
    entries = games_of_day(date).map { |game| entry(game) }

    # Einträge, an denen nach `.presence` weder Stream noch Aufzeichnung übrig ist,
    # gehören nicht in die Liste. Der SQL-Filter lässt jeden nicht-leeren Text durch,
    # also auch ein Feld, in dem nur Leerzeichen stehen. Ohne diesen Riegel stünde auf
    # der Seite eine Übertragung, die nirgendwohin führt.
    entries.reject! { |e| e[:live_stream_link].nil? && e[:vod_link].nil? }

    log_empty_but_games_exist(date) if entries.empty?

    entries.sort_by do |e|
      # `start_time` ist eine Textspalte, ein leerer Wert sortierte sonst VOR 09:00 --
      # das ungepflegte Spiel stünde über dem, das gleich angeworfen wird. Dasselbe
      # Muster wie in PublicSecretaryController.
      [STATUS_ORDER.fetch(e[:status], 9), e[:time].presence || '99:99', e[:game_number].to_i]
    end
  end

  # Eine leere Liste heißt auf der Seite "heute wird nichts übertragen". Genau so
  # sieht aber auch ein nicht mehr zutreffender Datumsvergleich aus, und zwar ohne
  # Fehler und ohne Logzeile. Diese eine Abfrage je Cache-Miss trennt die beiden
  # Fälle: Gibt es überhaupt Spieltage mit diesem Datum, war der Tag nicht ruhig,
  # sondern es ist nur an keinem ein Link hinterlegt -- und gibt es keinen einzigen,
  # obwohl Spiele stattfinden, ist das der Hinweis auf ein Formatproblem in der
  # Spalte (siehe games_of_day).
  def log_empty_but_games_exist(date)
    return unless GameDay.where(date: date.to_s).exists?

    Rails.logger.info("live_streams: #{date} hat Spieltage, aber keinen hinterlegten Stream-Link")
  end

  # Verglichen wird als Text und nicht über TO_DATE. `game_days.date` ist eine
  # String-Spalte, in der auch Unbrauchbares stehen kann ("TBD", ein leerer Wert,
  # ein 30. Februar). TO_DATE wirft daran und riss schon andere Übersichten in
  # einen 500er; ein Textvergleich lässt solche Zeilen einfach nicht zutreffen.
  #
  # Die Kehrseite, damit sie niemand übersieht: Der Vergleich ist zeichengenau.
  # `GameDay` hat keine Validierung auf das Format, und der Altdaten-Import
  # schreibt `datum` ungeprüft durch. Ein abweichend formatierter Wert
  # ("11.08.2026") trifft hier nicht zu, und weil dieser Abruf eine leere Liste
  # als "heute wird nichts übertragen" darstellt, ist so ein Datensatz nicht
  # bloß unsichtbar, sondern nicht von einem ruhigen Tag zu unterscheiden.
  # Deshalb die Zählung unten. Auf der Schreibseite gehört das an GameDay, siehe #380.
  #
  # Einen Index auf `game_days.date` gibt es NICHT (indiziert sind arena_id,
  # club_id, (league_id, number) und legacy_ref). Jeder Cache-Miss ist also ein
  # Seq Scan. Bei der Tabellengröße vertretbar, aber nicht so, wie es hier vorher
  # behauptet stand.
  def games_of_day(date)
    # Die Liga wird nur gelesen, nicht gefiltert – dafür genügt der Preload, ein
    # zweiter Join brächte nichts.
    Game.joins(:game_day)
        .includes({ home_team: League::TEAM_WITH_LOGO_PRELOAD },
                  { guest_team: League::TEAM_WITH_LOGO_PRELOAD },
                  { game_day: %i[league arena club] })
        .where(game_days: { date: date.to_s })
        # BTRIM, weil `<> ''` auch ein Feld mit reinen Leerzeichen durchlässt. Das
        # `.presence` im Eintrag macht daraus danach nil, übrig blieb ein Eintrag
        # ohne jeden Link.
        .where("COALESCE(BTRIM(games.live_stream_link), '') <> '' " \
               "OR COALESCE(BTRIM(games.vod_link), '') <> ''")
  end

  def entry(game)
    gd = game.game_day
    league = gd.league

    item = {
      game_id: game.id,
      game_number: game.game_number,
      date: gd.date,
      time: game.start_time,
      status: status_of(game),
      # `started`/`ended` müssen mit im Eintrag stehen: delay_live_scores
      # entscheidet daran, ob ein Zwischenstand zurückgehalten wird.
      started: game.started,
      ended: game.ended,
      current_period_title: game.current_period_title,
      league: league && { id: league.id, name: league.name, short_name: league.short_name },
      arena_name: gd.arena&.name,
      hosting_club: gd.hosting_club,
      home_team_id: game.home_team_id,
      home_team_name: game.home_team_name,
      home_team_logo: game.home_team&.logo_url_fallback,
      home_team_small_logo: game.home_team&.logo_small_url_fallback,
      guest_team_id: game.guest_team_id,
      guest_team_name: game.guest_team_name,
      guest_team_logo: game.guest_team&.logo_url_fallback,
      guest_team_small_logo: game.guest_team&.logo_small_url_fallback,
      live_stream_link: game.live_stream_link.presence,
      vod_link: game.vod_link.presence
    }

    # Wie Game#schedule_item: ohne Anpfiff gibt es keinen Stand, und ein
    # ausgewiesenes 0:0 vor dem Spiel wäre eine Falschaussage, keine Lücke.
    if game.started?
      item[:result] = game.result
      item[:result_string] = game.result_string
    end

    item
  end

  # Dieselbe Bedingung wie ApplicationController#running_entry? und
  # Game#ticker_hash: `started && !ended`, nicht `state == :running`. Letzteres
  # verlangt einen angelegten Spielbericht, und ein angepfiffenes Spiel ohne
  # Bericht galte damit als anstehend, obwohl es längst läuft.
  def status_of(game)
    return 'ended' if game.ended?
    return 'running' if game.started?

    'upcoming'
  end
end
