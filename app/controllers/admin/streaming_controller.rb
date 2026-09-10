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
      satz.save!

      link_hinweis = link_setzen(spiel, broadcast_id)

      spieltag = spiel.game_day
      antwort = entry(spiel.reload, spieltag, spieltag&.stream_key, satz)
      # Ob der Link geschrieben wurde, und wenn nicht, warum. Ohne diese Angabe
      # ist "warum steht im Spielplan nichts" von außen nicht zu beantworten.
      antwort[:link_written] = link_hinweis.nil?
      antwort[:link_skipped_reason] = link_hinweis
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

    private

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
        ended_reason: satz.ended_reason
      }
    end
  end
end
