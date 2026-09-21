module Admin
  # Die Datenbasis des Streaming-Bereichs: Welche Spiele stehen an, über welchen
  # Schlüssel laufen sie, und welche haben schon eine Übertragung?
  #
  # WARUM EIN EIGENER ABRUF UND NICHT `admin_game_schedule`: Der Spielplan einer
  # Liga liefert die Spieltage EINER Liga, und ein Spieltag ist dort ein
  # Spieltags-ORT (Halle plus Ausrichter). Die Streams eines Wochenendes werden
  # aber quer über die Ligen eingerichtet, nach Anwurfzeit sortiert -- so ist auch
  # die bisherige Excel-Vorlage der Spielbetriebskommission aufgebaut. Wer das aus
  # dem Ligaspielplan zusammensetzen wollte, müsste vier Abrufe machen und selbst
  # sortieren, und die Spieltagsnummer über die Hallen hinweg selbst gruppieren.
  #
  # Deshalb zwei Zuschnitte auf denselben Daten:
  #   * `from`/`to`          -- das Wochenende quer über alle gestreamten Ligen
  #   * `league_id` + `game_day_number` -- "Spieltag 1" einer Liga, alle Hallen
  #
  # NUR ADMIN UND FD-SBK. Der Schlüssel ist ein Geheimnis (wer ihn hat, sendet auf
  # den Verbandskanal), und die Übertragungen richtet eine Stelle zentral ein.
  # `permission_hash` klappt einen SBK für einen nationalen Spielbetrieb auf
  # Scope 0 zusammen, ein Landesverbands-SBK trägt dagegen seine eigene ID --
  # dieselbe Regel wie beim Lebenszyklus der Spielorte.
  class StreamingController < ApplicationController
    before_action :authenticate_user
    before_action :authorize!
    # Verbinden und Trennen sind ADMIN ALLEIN: Wer hier zustimmt, haengt den
    # Verbandskanal an ein Google-Konto, und der Zugang ueberlebt jede Sitzung.
    # Das Anlegen einzelner Uebertragungen (FD-SBK) ist demgegenueber eine
    # Tageshandlung mit einem Token, das nach einer Stunde verfaellt.
    before_action :authorize_admin!, only: %i[connect_youtube disconnect_youtube]

    # Ein Zeitraum ist zum Einrichten eines Spieltags oder Wochenendes gedacht.
    # Ohne Deckel holt ein vertipptes Jahr die halbe Saison in einer Antwort, mit
    # Wappen-URLs je Mannschaft.
    MAX_RANGE_DAYS = 31

    # GET admin/streaming/games
    def games
      spieltage = scoped_game_days
      return if performed?

      # `:club` an den Mannschaften ist nicht schmückendes Beiwerk: `meta_hash`
      # liest `logo_url_fallback`, und das fällt auf das Vereinswappen zurück.
      # Ohne das Mitladen sind das zwei zusätzliche Abfragen je Spiel -- derselbe
      # Fall, den GameDay#full_hash bereits kommentiert löst.
      spieltage = spieltage.includes(
        :league, :arena, :club,
        games: [{ home_team: :club }, { guest_team: :club }]
      ).to_a
      spiele = spieltage.flat_map(&:games)
      saetze = StreamBroadcast.where(game_id: spiele.map(&:id)).order(:created_at).index_by(&:game_id)

      eintraege = spieltage.flat_map do |spieltag|
        # Ein Abruf je Spieltag (GameDay#hosting_team), bewusst statt einer
        # gebündelten Abfrage: Wer ausrichtet, wird an genau einer Stelle
        # beantwortet, und die Liste ist durch MAX_RANGE_DAYS klein gehalten.
        schluessel = spieltag.stream_key
        spieltag.games.map { |spiel| entry(spiel, spieltag, schluessel, saetze[spiel.id]) }
      end

      # Nach Anwurf, wie die Vorlage: Wer Streams einrichtet, arbeitet den Tag
      # der Reihe nach ab. Spiele ohne Anwurfzeit ans Ende statt in eine
      # Ausnahme -- sie sind unfertig gepflegt, aber kein Fehler.
      render json: eintraege.sort_by { |e| e[:start_at] || '9999' }
    end

    # POST admin/streaming/games/:id/broadcast
    #
    # Meldet zurück, dass für dieses Spiel eine YouTube-Übertragung angelegt
    # wurde. Angelegt wird sie im Browser -- dort liegt das fertige Thumbnail,
    # und nur dort ist jemand angemeldet, der auf dem Kanal schreiben darf.
    #
    # ZWEIMAL AUFGERUFEN, UND DAS IST ABSICHT: Der erste Aufruf kommt direkt nach
    # dem Anlegen und dient nur der Registrierung -- ab da existiert die
    # Übertragung, und der Wächter muss sie kennen, auch wenn danach etwas
    # schiefgeht. Der zweite kommt nach dem Binden mit `bound=true` und gibt den
    # Link für den öffentlichen Spielplan frei. Ohne diese Trennung stünde dort
    # ein Link auf eine Übertragung, die nie Signal bekommt: Der Wächter
    # überspringt ungebundene Übertragungen ausdrücklich, beendet sie also auch
    # nie, und der tote Link bliebe stehen.
    def record_broadcast
      spiel = Game.find_by(id: params[:id])
      return render json: { error: 'Spiel nicht gefunden' }, status: :not_found unless spiel

      broadcast_id = params[:broadcast_id].to_s.strip
      return render json: { error: 'broadcast_id fehlt' }, status: :bad_request if broadcast_id.blank?

      satz = StreamBroadcast.find_or_initialize_by(broadcast_id: broadcast_id)

      # Dieselbe Übertragung für ein anderes Spiel zu melden ist fast immer ein
      # Versehen (kopierte Kennung). Stillschweigend umzuhängen ließe das alte
      # Spiel mit einem `live_stream_link` auf eine Übertragung zurück, die im
      # Streaming-Bereich dort nicht mehr auftaucht.
      if satz.game_id.present? && satz.game_id != spiel.id
        return render json: { error: 'Diese Übertragung ist bereits einem anderen Spiel zugeordnet.' },
                      status: :conflict
      end

      # `.presence` nur beim Setzen, nicht beim Leeren: Ein zweiter Aufruf ohne
      # Titel darf den vorhandenen nicht löschen.
      satz.game_id = spiel.id
      satz.title = params[:title] if params[:title].present?
      satz.stream_id = params[:stream_id] if params[:stream_id].present?
      # Ob nach dem Spiel veroeffentlicht wird, entscheidet der SERVER und nicht
      # der Browser: Der Browser meldet nur, womit er angelegt hat. Die Zusage
      # steht am Ausrichter, und nur beides zusammen ergibt den Auftrag -- wer
      # aus einem anderen Grund nicht gelistet anlegt (Probelauf), bekommt keine
      # automatische Veroeffentlichung, und wer bei einem Zusage-Ausrichter
      # bewusst oeffentlich anlegt, braucht keine.
      #
      # Einseitig und nie zuruecknehmend: Der zweite Aufruf (nach dem Binden)
      # darf einen inzwischen abgewaehlten Haken nicht gegen die Uebertragung
      # wenden, die bereits laeuft. `||=` statt `if new_record?`, weil der
      # Waechter den Satz zuerst angelegt haben kann (erste Meldung gescheitert,
      # Uebertragung schon live) -- dann stuende sonst fuer immer `false` darin,
      # und die Zusage waere still verloren.
      satz.promote_to_public ||= zusage_greift?(spiel, params[:privacy_status])
      satz.save!

      link_hinweis = link_setzen(spiel, broadcast_id)

      spieltag = spiel.game_day
      antwort = entry(spiel.reload, spieltag, spieltag&.stream_key, satz)
      # Ob der Link geschrieben wurde, und wenn nicht, warum. Ohne diese Angabe
      # ist "warum steht im Spielplan nichts" von außen nicht zu beantworten.
      antwort[:link_written] = link_hinweis.nil?
      antwort[:link_skipped_reason] = link_hinweis
      # Der einzige nicht rueckholbare Fehler, und der Server ist die einzige
      # Stelle, die ihn sehen kann: Die Oberflaeche entscheidet nach der Liste,
      # die sie geladen hat -- wird die Zusage danach in einer anderen Sitzung
      # gesetzt, legt sie oeffentlich an, ohne es zu wissen. Geblockt wird
      # nichts (die Uebertragung existiert bei YouTube bereits), aber sie wird
      # laut.
      antwort[:zusage_uebergangen] = zusage_uebergangen?(spiel, params[:privacy_status])
      render json: antwort, status: :created
    end

    # GET admin/streaming/settings
    def settings
      render json: templates_hash
    end

    # PUT admin/streaming/settings
    #
    # Die Vorlagen liegen in den Einstellungen und nicht im Browser: Die Titel
    # sind öffentlich und sollen einheitlich sein, unabhängig davon, wer den
    # Knopf drückt.
    def update_settings
      setting = Setting.current
      return render json: { error: 'Einstellungen nicht gefunden' }, status: :not_found unless setting

      # Leer heißt "wieder die Vorgabe", nicht "leerer Titel": Ein Stream ohne
      # Titel wäre bei YouTube namenlos, und ein leeres Feld ist der
      # naheliegende Weg, eine verunglückte Vorlage loszuwerden.
      # Nur anfassen, was wirklich übergeben wurde. Aus einem unvollständigen
      # Aufruf einen vollständigen Zustand zu bauen, setzte bei einem `PUT` mit
      # nur `title` die Beschreibung unbemerkt auf die Vorgabe zurück -- was wie
      # ein Anzeigefehler aussieht und Datenverlust ist.
      neu = (setting.stream_templates || {}).dup
      neu['title'] = params[:title].to_s.strip if params.key?(:title)
      neu['description'] = params[:description].to_s.strip if params.key?(:description)

      setting.update!(stream_templates: neu.compact_blank)
      render json: templates_hash
    end

    # GET admin/streaming/youtube
    #
    # Woran der Waechter haengt und ob er ueberhaupt haengt. Ohne diese Auskunft
    # ist ein abgelaufener Zugang von aussen nicht zu sehen: Der Waechter laeuft
    # als Cronjob, und sein Scheitern faellt sonst erst auf, wenn eine
    # Uebertragung nach dem Spiel weiterlaeuft.
    def youtube
      render json: youtube_hash
    end

    # POST admin/streaming/youtube
    #
    # Der Code stammt aus dem Anmeldedialog im Browser. Nur der Server kann ihn
    # einloesen, und nur dabei entsteht der dauerhafte Zugang.
    def connect_youtube
      unless YoutubeOauth.configured?
        return render json: { error: 'Der Verbindungsweg ist nicht eingerichtet, es fehlt: ' \
                                     "#{YoutubeOauth.fehlende_einstellungen.join(', ')}" },
                      status: :unprocessable_entity
      end

      satz = YoutubeOauth.new(code: params[:code], redirect_uri: params[:redirect_uri])
                         .verbinden!(user: current_user)
      render json: youtube_hash(satz)
    rescue YoutubeOauth::NoRefreshToken
      render json: { error: 'Google hat keinen dauerhaften Zugang ausgegeben. Das passiert, wenn ' \
                            'dieses Konto der Anwendung schon zugestimmt hat: Den Zugriff unter ' \
                            'myaccount.google.com/permissions entfernen und erneut verbinden.' },
             status: :unprocessable_entity
    rescue YoutubeOauth::LiveStreamingDisabled
      render json: { error: 'Der gewaehlte Kanal ist nicht fuer Livestreaming freigeschaltet. Am ' \
                            'Konto haengen zwei gleichnamige Kanaele -- bitte den mit den Videos ' \
                            'waehlen.' },
             status: :unprocessable_entity
    rescue YoutubeOauth::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # DELETE admin/streaming/youtube
    #
    # Widerruft den Zugang ZUERST bei Google und raeumt ihn dann oertlich ab.
    # Ohne den Widerruf waere das Trennen eine Sackgasse: Einen Refresh-Token
    # gibt Google nur bei der ersten Zustimmung eines Kontos heraus, ein
    # anschliessendes Neuverbinden liefe also in `NoRefreshToken`.
    def disconnect_youtube
      satz = StreamCredential.current
      YoutubeOauth.revoke(satz&.refresh_token)
      satz&.update!(refresh_token: nil, client_id: nil, channel_id: nil, channel_title: nil,
                    connected_at: nil, connected_by_user_id: nil)
      render json: youtube_hash
    end

    # GET admin/streaming/hosts
    #
    # Die Pflegeliste der Zusagen. Enthalten sind die Vereine, die in der
    # laufenden Saison ueberhaupt ausrichten, plus jeder Verein mit gesetzter
    # Zusage -- sonst liesse sich eine Zusage nicht mehr abwaehlen, sobald der
    # Verein einmal keinen Spieltag ausrichtet.
    def hosts
      ausrichter_ids = GameDay.joins(:league)
                              .where(leagues: { season_id: Setting.current_season_id.to_s })
                              .where.not(club_id: nil)
                              .distinct
                              .pluck(:club_id)

      vereine = Club.where(id: ausrichter_ids)
                    .or(Club.where(stream_default_unlisted: true))
                    .order(:name)

      render json: vereine.map { |verein| host_hash(verein) }
    end

    # PUT admin/streaming/hosts/:id
    def update_host
      verein = Club.find_by(id: params[:id])
      return render json: { error: 'Verein nicht gefunden' }, status: :not_found unless verein

      # Ohne den Riegel setzt ein fehlender Parameter die Zusage still auf false
      # -- ein halbfertiger Aufruf naehme einem Verein seine Zusage, ohne dass es
      # jemand sieht.
      wert = params[:stream_default_unlisted]
      # `blank?` und nicht `nil?`: Ein leerer Wert ist derselbe halbfertige
      # Aufruf und naehme dem Verein genauso still seine Zusage.
      if wert.blank? && wert != false
        return render json: { error: 'stream_default_unlisted fehlt' }, status: :bad_request
      end

      verein.update!(stream_default_unlisted: ActiveModel::Type::Boolean.new.cast(wert) || false)
      render json: host_hash(verein)
    end

    # GET admin/streaming/teams
    #
    # Die Pflegeliste der Streamschluessel. Bis hierher war der Schluessel nur
    # ueber `rake streaming:import_keys` zu setzen, und der Task ersetzt einen
    # bestehenden Wert bewusst NICHT -- ein geaenderter Schluessel brauchte
    # deshalb eine Handzeile auf der Produktion.
    #
    # Gezeigt werden die Mannschaften der laufenden Saison aus jeder Liga, in
    # der ueberhaupt schon ein Schluessel haengt, plus auf Wunsch eine weitere
    # ueber `league_id`. Ohne diesen Zusatz waere die Liste einer neu
    # gestreamten Liga leer, bevor der erste Schluessel drin ist -- derselbe
    # Fall, den `scoped_game_days` fuer den Spieltags-Zuschnitt schon loest.
    def teams
      liga_ids = key_league_ids
      # `to_s` vor `to_i`: `?league_id[]=5` liefert ein Array, und `Array#to_i`
      # gibt es nicht -- ohne den Umweg waere ein vertippter Parameter eine 500
      # samt Sentry-Ereignis statt einer leeren Zusatzliga.
      liga_ids += [params[:league_id].to_s.to_i] if params[:league_id].present?

      mannschaften = Team.where(league_id: liga_ids)
                         .where(league_id: League.current_season.select(:id))
                         .includes(:league, :club)
                         .to_a

      # Nach Liga und Mannschaft, damit die Liste dieselbe Ordnung hat wie das
      # Blatt der Spielbetriebskommission, aus dem die Schluessel kommen.
      sortiert = mannschaften.sort_by { |team| [team.league&.name.to_s, team.name.to_s] }
      render json: sortiert.map { |team| team_hash(team) }
    end

    # PUT admin/streaming/teams/:id
    def update_team
      team = Team.find_by(id: params[:id])
      return render json: { error: 'Mannschaft nicht gefunden' }, status: :not_found unless team

      # Nur die laufende Saison: Ein Schluessel an einer abgelaufenen Mannschaft
      # aendert nichts mehr an einer Uebertragung, die Verwechslungsgefahr mit
      # der gleichnamigen Mannschaft der neuen Saison bleibt aber.
      unless team.league&.season_id.to_s == Setting.current_season_id.to_s
        return render json: { error: 'Mannschaft gehoert nicht zur laufenden Saison' },
                      status: :unprocessable_entity
      end

      # Derselbe Riegel wie bei den Zusagen: Ohne ihn loeschte ein
      # halbfertiger Aufruf den Schluessel, und der Ausfall faellt erst am
      # Spieltag auf, wenn der Waechter die Uebertragung keinem Spiel zuordnet.
      return render json: { error: 'stream_key fehlt' }, status: :bad_request unless params.key?(:stream_key)

      schluessel = params[:stream_key].to_s.strip
      if schluessel.empty?
        team.update!(stream_key: nil)
        return render json: team_hash(team)
      end

      # Ein Schluessel mit Leerzeichen ist ein Kopierfehler aus der Tabelle.
      # Er wuerde anstandslos gespeichert und erst bei YouTube auffallen.
      if schluessel.match?(/\s/)
        return render json: { error: 'Der Schluessel darf keine Leerzeichen enthalten' },
                      status: :unprocessable_entity
      end

      # Dieselbe Sperre wie im Importtask: Zwei Mannschaften mit demselben
      # Schluessel sind fuer den Waechter mehrdeutig, er ordnet dann NICHTS zu.
      # Ueber Saisongrenzen hinweg ist der doppelte Wert dagegen normal, denn
      # bei YouTube ueberlebt der Schluessel die Saison.
      doppelt = Team.where(stream_key: schluessel)
                    .where(league_id: League.current_season.select(:id))
                    .where.not(id: team.id)
                    .includes(:league).first
      if doppelt
        return render json: { error: "Dieser Schluessel haengt schon an #{doppelt.name} " \
                                     "(#{doppelt.league&.name})" },
                      status: :unprocessable_entity
      end

      team.update!(stream_key: schluessel)
      render json: team_hash(team)
    end

    private

    # Der Wert selbst geht NICHT zurueck. Die Liste dient dem Pflegen, nicht dem
    # Nachschlagen: Wer den Schluessel braucht, hat ihn aus der Halle oder aus
    # dem Blatt der Spielbetriebskommission. Die letzten vier Zeichen reichen,
    # um zu erkennen, ob der eingetragene derselbe ist -- und sie taugen nicht
    # zum Senden.
    def team_hash(team)
      schluessel = team.stream_key.presence
      {
        id: team.id,
        name: team.name,
        club_name: team.club&.name,
        league_id: team.league_id,
        league_name: team.league&.name,
        has_stream_key: schluessel.present?,
        stream_key_hint: schluessel&.last(4)
      }
    end

    # Die Ligen der laufenden Saison, um die es beim Streaming geht: jede mit
    # mindestens einem Schluessel -- PLUS jede mit gepflegter Playlist.
    #
    # Der Zusatz ist derselbe Gedanke wie bei den Zusagen (`hosts` zaehlt jeden
    # Verein mit gesetztem Haken mit): Ohne ihn verschwaende das Loeschen des
    # letzten Schluessels einer Liga die ganze Liga aus der Liste, und wer einen
    # Schluessel von einer Mannschaft auf eine andere umtraegt, faende die
    # zweite nicht mehr. Die Playlist steht an genau den Ligen, die auf den
    # Verbandskanal gehen.
    def key_league_ids
      League.current_season
            .where(id: streamed_league_ids)
            .or(League.current_season.where.not(stream_playlist: [nil, '']))
            .pluck(:id)
    end

    def youtube_hash(satz = nil)
      satz ||= StreamCredential.current
      # EINMAL nachschlagen: Jeder Aufruf von `credentials` liest die Zeile und
      # entschluesselt sie.
      zugang = YoutubeLiveApi.credentials
      # Liegt eine gespeicherte Zeile vor, wird aber NICHT benutzt? Das
      # passiert, wenn die Kennung in der Google Cloud getauscht oder
      # `YOUTUBE_TOKEN_KEY` geaendert wurde: `credentials` faellt dann still auf
      # die Umgebung zurueck. Ohne diese Angabe stuende auf der Seite
      # „verbunden" samt Kanal und Zeitpunkt aus einer Zeile, die niemand mehr
      # benutzt -- genau der unsichtbare Zustand, den dieser Abruf aufdecken soll.
      satz_aktiv = zugang&.fetch(:source) == 'db'
      {
        connected: zugang.present?,
        stored_present: satz.present? && satz.connected?,
        stored_active: satz_aktiv,
        # 'db' heisst ueber die Oberflaeche verbunden, 'env' ueber die Variablen
        # am Container. Der Unterschied entscheidet, ob ein Neuverbinden hier
        # ueberhaupt etwas aendert.
        source: zugang&.fetch(:source),
        channel_id: satz&.channel_id,
        channel_title: satz&.channel_title,
        connected_at: satz&.connected_at&.iso8601,
        connected_by: satz&.connected_by&.fullname.presence,
        can_connect: YoutubeOauth.configured?,
        # Ob DIESE Person verbinden darf. Die Oberflaeche soll den Knopf nicht
        # anbieten, wo der Server ihn ablehnt -- und die Rolle steht nicht in
        # den Berechtigungen, die im Browser liegen (dort stehen Menuepunkte).
        may_connect: current_user.permission_hash[:admin].present?,
        missing_settings: YoutubeOauth.fehlende_einstellungen,
        # Die Kennung kommt vom Server und nicht aus dem Bundle: Eingeloest wird
        # der Code mit dem Paar, das hier liegt. Weichen beide voneinander ab,
        # scheiterte die Anmeldung erst beim Einloesen und niemand saehe, warum.
        client_id: ENV.fetch('YOUTUBE_WEB_CLIENT_ID', nil)
      }
    end

    def host_hash(verein)
      {
        id: verein.id,
        name: verein.name,
        short_name: verein.short_name,
        stream_default_unlisted: verein.stream_default_unlisted
      }
    end

    # Die Zusage greift nur, wenn BEIDES zutrifft: Der Ausrichter hat sie, und
    # die Uebertragung wurde tatsaechlich nicht gelistet angelegt.
    def zusage_greift?(spiel, gemeldete_sichtbarkeit)
      return false unless gemeldete_sichtbarkeit.to_s == 'unlisted'

      spiel.game_day&.stream_privacy_default == 'unlisted'
    end

    def zusage_uebergangen?(spiel, gemeldete_sichtbarkeit)
      return false unless spiel.game_day&.stream_privacy_default == 'unlisted'
      return false if gemeldete_sichtbarkeit.to_s == 'unlisted'

      if defined?(Sentry)
        Sentry.capture_message(
          'Uebertragung oeffentlich angelegt, obwohl der Ausrichter eine Zusage hat',
          level: :warning,
          extra: { game_id: spiel.id, club_id: spiel.game_day&.club_id }
        )
      end
      true
    end

    def templates_hash
      {
        title: Setting.stream_title_template,
        description: Setting.stream_description_template,
        default_title: Setting::DEFAULT_STREAM_TITLE,
        default_description: Setting::DEFAULT_STREAM_DESCRIPTION
      }
    end

    def authorize!
      ph = current_user.permission_hash
      return if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def scoped_game_days
      if params[:league_id].present? && params[:game_day_number].present?
        # Ausdrücklich eine Liga: dann auch dann zeigen, wenn dort noch kein
        # Schlüssel gepflegt ist -- sonst wäre die Ansicht vor dem ersten Import
        # leer und niemand wüsste, warum.
        GameDay.where(league_id: params[:league_id], number: params[:game_day_number])
      elsif params[:from].present? && params[:to].present?
        game_days_in_range
      else
        render json: { error: 'Entweder from und to oder league_id und game_day_number angeben' },
               status: :bad_request
        nil
      end
    end

    def game_days_in_range
      von = Date.parse(params[:from].to_s)
      bis = Date.parse(params[:to].to_s)

      if bis < von
        return render json: { error: 'to liegt vor from' }, status: :bad_request
      end

      if (bis - von).to_i + 1 > MAX_RANGE_DAYS
        return render json: { error: "Zeitraum umfasst höchstens #{MAX_RANGE_DAYS} Tage" },
                      status: :bad_request
      end

      # Über den Zeitraum nur die Ligen, in denen überhaupt gestreamt wird. Ohne
      # diese Grenze stünden an einem Bundesliga-Wochenende sämtliche Spiele
      # sämtlicher Landesverbände in der Liste, von denen kein einziges auf den
      # Verbandskanal geht.
      GameDay.where(date: (von..bis).map(&:to_s), league_id: streamed_league_ids)
    rescue Date::Error
      # `from` und `to` kommen als Freitext aus der Adresszeile. Ohne diesen
      # Riegel käme ein Tippfehler als 500 zurück, obwohl er ein Eingabefehler ist.
      render json: { error: 'from und to müssen Datumsangaben im Format JJJJ-MM-TT sein' },
             status: :bad_request
    end

    def streamed_league_ids
      Team.where.not(stream_key: nil).select(:league_id)
    end

    # Der Link ins öffentliche Spielplanbild. Geschrieben wird er nur, wenn die
    # Übertragung öffentlich ist UND am Spiel noch keiner steht:
    #
    #   * Vereine senden parallel auf ihren EIGENEN Kanal, damit kein zweiter
    #     Upload nötig ist. Steht dort schon ihr Link, ist er der richtige --
    #     unser Mitschnitt kann nicht-öffentlich sein.
    #   * Eine nicht-öffentliche Übertragung im Spielplan wäre ein toter Link für
    #     jeden Zuschauer.
    #
    # Überschreiben darf der Verein jederzeit: Das Feld steht im Spielbericht,
    # und dieser Abruf fasst einen vorhandenen Wert nie an.
    def link_setzen(spiel, broadcast_id)
      # Erst wenn die Übertragung an ihren Stream gebunden ist. Vorher empfängt
      # sie kein Signal, und ihr Link wäre im öffentlichen Spielplan tot.
      return 'noch nicht an den Stream gebunden' unless bound?
      return 'nicht öffentlich' unless params[:privacy_status].to_s == 'public'
      return 'am Spiel steht bereits ein Link' if spiel.live_stream_link.present?

      # `update!` und NICHT `update_columns`: Game trägt
      # `after_commit :flush_league_caches`, und `live_stream_link` steckt über
      # `meta_hash` im gecachten Spielplan der Liga. Mit `update_columns` stünde
      # der Link in der Datenbank, im öffentlichen Spielplan aber erst nach
      # Ablauf des Zwischenspeichers -- genau in den Minuten vor dem Anwurf, in
      # denen die Zuschauer ihn suchen.
      #
      # Damit läuft auch `before_save :correct_teams!` mit, das eine
      # Mannschafts-ID von 0 auf nil normalisiert. Das ist gewollt und keine
      # Nebenwirkung, die es zu vermeiden gälte: Dieselbe Reparatur nimmt jeder
      # andere Speicherweg am Spiel ebenfalls vor, und eine 0 ist dort in keinem
      # Fall ein gültiger Wert. Den Callback zu umgehen hieße, eine kaputte
      # Zeile bewusst kaputt zu lassen.
      spiel.update!(live_stream_link: "https://www.youtube.com/watch?v=#{broadcast_id}")
      nil
    end

    # Fehlt die Angabe, gilt die Übertragung als gebunden.
    #
    # Der Streaming-Bereich schickt sie in beiden Aufrufen mit und steuert damit,
    # wann der Link öffentlich wird. Ein Aufrufer, der das Flag nicht kennt (ein
    # Skript, ein älteres Frontend), hat aber keinen zweiten Aufruf, der es
    # nachreicht -- für ihn bliebe der Link dauerhaft aus, und der Grund stünde
    # nur in einem Feld, das er nicht liest. Das Zurückhalten ist die Ausnahme
    # und muss deshalb ausdrücklich angefordert werden, nicht die Vorgabe sein.
    def bound?
      return true unless params.key?(:bound)

      ActiveModel::Type::Boolean.new.cast(params[:bound]).present?
    end

    def entry(spiel, spieltag, schluessel, satz)
      spiel.meta_hash.merge(
        start_at: spiel.start_date&.iso8601,
        # Die öffentliche Spielseite baut `Game#url` -- das Verbandssegment ist
        # `GameOperation#slug` und nicht der kleingeschriebene Kurzname, und
        # diese Regel soll nicht ein zweites Mal im Frontend stehen. Die
        # Beschreibung der Übertragung verweist darauf.
        public_url: spiel.url,
        stream_key: schluessel,
        streamable: schluessel.present?,
        # Was dieses Spiel bekommt, wenn niemand etwas anderes einstellt. Je
        # Spiel und nicht einmal je Lauf: Die Zusage haengt am Ausrichter, und
        # ein Wochenende enthaelt beides. Die Oberflaeche zeigt es an der Zeile
        # an -- eine stille Abweichung von dem, was oben eingestellt ist, liest
        # sich wie ein Fehler.
        privacy_default: spieltag&.stream_privacy_default || 'public',
        game_day: game_day_hash(spieltag),
        league: league_hash(spieltag&.league),
        broadcast: broadcast_hash(satz)
      )
    end

    def game_day_hash(spieltag)
      return nil unless spieltag

      {
        id: spieltag.id,
        number: spieltag.number,
        date: spieltag.date,
        league_id: spieltag.league_id,
        hosting_club: spieltag.hosting_club,
        hosting_club_id: spieltag.club_id,
        hosting_club_unlisted: spieltag.club&.stream_default_unlisted || false,
        arena: { name: spieltag.arena&.name, city: spieltag.arena&.city }
      }
    end

    def league_hash(liga)
      return nil unless liga

      { id: liga.id, name: liga.name, short_name: liga.short_name, stream_playlist: liga.stream_playlist }
    end

    def broadcast_hash(satz)
      return nil unless satz

      {
        broadcast_id: satz.broadcast_id,
        watch_url: "https://www.youtube.com/watch?v=#{satz.broadcast_id}",
        created_at: satz.created_at,
        ended_at: satz.ended_at,
        ended_reason: satz.ended_reason,
        promote_to_public: satz.promote_to_public,
        promoted_at: satz.promoted_at
      }
    end
  end
end
