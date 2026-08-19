# Rack wertet seit 3.1 zuerst den RFC-7239-Header `Forwarded` aus und erst
# danach `X-Forwarded-For` (Rack::Request.forwarded_priority). nginx setzt in
# proxy.conf nur X-Forwarded-For und reicht ein mitgeschicktes `Forwarded`
# unverändert durch. Damit bestimmt der Client selbst, was req.ip liefert, und
# jede Drosselung pro IP wäre mit einem Header abschaltbar – auch die beiden
# unten, die Mail-Fluten und das Durchprobieren von Einmal-Links begrenzen.
#
# Maßgeblich ist deshalb allein die Kette, die der eigene Reverse Proxy
# schreibt.
Rack::Request.forwarded_priority = [:x_forwarded]

module Rack
  class Attack
    # IPs, die dauerhaft abgewiesen werden. Bewusst eine kurze, kommentierte
    # Liste im Code statt einer Tabelle: Ein Eintrag ist die Ausnahme, soll
    # begründet sein und beim Lesen erklären, warum er noch da ist.
    #
    # Wirksam ist das nur, weil `req.ip` nicht vom Client bestimmbar ist: nginx
    # setzt X-Forwarded-For über `$proxy_add_x_forwarded_for`, hängt die echte
    # Adresse also hinten an eine mitgeschickte Kette, und Rack nimmt daraus die
    # letzte nicht-vertraute Adresse. Zusammen mit `forwarded_priority` oben
    # (siehe Kommentar am Dateikopf) laesst sich ein Bann nicht per Header
    # abschütteln.
    #
    # Vor dem Entfernen eines Eintrags: kurz ins Log sehen, ob die Adresse noch
    # anfragt. Ein stiller Dauergast wird sonst unbemerkt wieder durchgelassen.
    BLOCKED_IPS = {
      # 19.08.2026, IONOS-Shared-Hosting (infongq-eu99.clienthosting.eu).
      # Fragte im 42-Sekunden-Takt vier Pfade ab und bekam auf alle nichts:
      # `games/46299.json` und `game_operations/1/leagues.json` mit 401 (kein
      # gültiger API-Key), dazu `fvd/leagues.json` und `FVD/leagues.json` mit
      # 404 — die Route hat es nie gegeben, offenbar aus den öffentlichen
      # Frontend-URLs (/fvd/…) geraten. Spiel 46299 ist seit dem 21.07.
      # abgeschlossen, da lief also eine vergessene Anzeigetafel gegen ein
      # beendetes Spiel. Kein Angriff, aber rund 6500 Zeilen Log am Tag: Rails
      # meldet den Routing-Fehler als FATAL, und das verdeckt echte Fehler.
      # Shared Hosting heisst: hinter der Adresse koennen fremde Kundenseiten
      # liegen. Vertretbar, weil von dieser IP keine einzige Anfrage je
      # beantwortet wurde, es also keinen laufenden Zugriff zu zerstoeren gibt.
      '82.165.87.204' => 'kein Key, geratene Routen, seit Wochen nur 401/404'
    }.freeze

    blocklist('blocked-ips') do |req|
      BLOCKED_IPS.key?(req.ip)
    end

    # Kein 403 mit Erklaerung: Wer hier landet, ist entweder ein vergessenes
    # Skript, das die Antwort nie liest, oder jemand, dem wir nichts ueber die
    # Regel verraten muessen. 404 ohne Rumpf ist die knappste wahre Aussage —
    # fuer diese Adresse gibt es hier nichts.
    self.blocklisted_responder = lambda do |_req|
      [404, { 'Content-Type' => 'application/json' }, ['{}']]
    end

    # Offene Endpunkte, die Mail an eine von außen bestimmte Adresse auslösen.
    # Sie brauchen weder Login noch API-Key, fallen also nicht unter den
    # Key-Throttle weiter unten.
    MAIL_TRIGGER_PATHS = %w[/api/v2/forgot_username /api/v2/lost_password].freeze

    # Pro IP drosseln, weil die fachlichen Wartezeiten in den Controllern nur je
    # Zieladresse greifen und das Gesamtvolumen nicht begrenzen: Mit einer Liste
    # von Mitgliedsadressen ließen sich sonst beliebig viele Postfächer parallel
    # zumüllen, auf Kosten der Reputation der Absenderdomain.
    #
    # Das 429 verrät hier nichts: Es hängt an der IP des Absenders, nicht an der
    # Zieladresse, und lässt daher weiterhin offen, welche Adressen im System
    # hinterlegt sind.
    #
    # nginx setzt X-Forwarded-For (nginx/config/proxy.conf), req.ip ist also die
    # echte Client-IP und nicht die des Reverse Proxy – siehe die
    # forwarded_priority-Zuweisung oben, ohne die ein mitgeschickter
    # `Forwarded`-Header Vorrang hätte.
    throttle('mail-trigger/ip', limit: 10, period: 1.hour) do |req|
      req.ip if req.post? && MAIL_TRIGGER_PATHS.include?(req.path)
    end

    # Einmal-Links für das Schiri-Feedback (Abgabe ohne Anmeldung). Der Token ist
    # die einzige Berechtigung, deshalb wird das Durchprobieren gedrosselt. Der
    # Endpunkt braucht weder Login noch API-Key, fällt also ebenfalls nicht unter
    # den Key-Throttle weiter unten.
    throttle('referee-feedback-invitation/ip', limit: 30, period: 1.hour) do |req|
      req.ip if req.path.start_with?('/api/v2/referee_feedback_invitations')
    end

    # Antrag auf einen API-Zugang. Löst Mail an ein festes Postfach aus, gehört
    # damit in dieselbe Kategorie wie MAIL_TRIGGER_PATHS. Der Key-Throttle weiter
    # unten hilft hier nicht: Er greift nur bei Keys mit gesetztem Rate-Limit, und
    # der Frontend-Key hat keines.
    throttle('api-key-application/ip', limit: 10, period: 1.hour) do |req|
      req.ip if req.post? && req.path == '/api/v2/api_key_applications'
    end

    # Abholen des genehmigten Keys über den Einmal-Link. Bewusst ein eigener,
    # größerer Topf: Das Durchprobieren von Tokens soll gedrosselt sein, aber ein
    # Antragsteller, der die Seite mehrfach lädt oder neu aufruft, darf sich nicht
    # selbst vom eigenen Schlüssel aussperren – der lässt sich nur ein einziges
    # Mal abholen. Grenze wie beim Feedback-Einmal-Link.
    throttle('api-key-reveal/ip', limit: 30, period: 1.hour) do |req|
      req.ip if req.path.start_with?('/api/v2/api_key_applications/reveal')
    end

    # Kalender-Abos (ICS). Der einzige öffentliche Bereich, der WEDER ein Cookie
    # NOCH einen API-Key verlangt: Kalender-Programme können keine eigene
    # Kopfzeile mitschicken, ein Abo wäre mit Key-Zwang technisch unmöglich.
    #
    # Damit fällt der Abruf durch beide Netze weiter unten. Der Key-Throttle
    # zählt nur Keys mit gesetzter Grenze, und der Crawler-Throttle nur bekannte
    # Kennungen – ein Aufruf mit gewöhnlicher Browser-Kennung und ohne Key liefe
    # sonst völlig ungebremst. Bis hierher deckelte immer eine Grenze je
    # Schlüssel den Aufwand, und billig ist der Aufruf nicht: Der Liga-Kalender
    # liest alle Spiele einer Liga und serialisiert sie.
    #
    # 30 pro Minute ist reichlich bemessen und trifft keinen echten Nutzer:
    # Kalender-Programme gleichen höchstens stündlich ab, meist seltener, und
    # wer den Link im Browser anklickt, kommt auf einzelne Aufrufe. Die Antwort
    # ist zusätzlich eine Stunde öffentlich cachebar (IcalRenderable), womit
    # wiederholte Abrufe desselben Abos hier gar nicht erst ankommen.
    #
    # Der Pfad ohne api/v2-Präfix ist mitgenommen, obwohl nginx ihn nicht
    # durchreicht: Er steht in config/routes.rb und wäre erreichbar, sobald
    # jemand eine location dafür einträgt.
    throttle('calendar/ip', limit: 30, period: 1.minute) do |req|
      next unless req.get? || req.head?

      req.ip if req.path.start_with?('/api/v2/calendar/', '/calendar/')
    end

    # Suchmaschinen und Skript-Clients stellen den größten Teil des Verkehrs auf
    # den öffentlichen Endpunkten. Messung Produktion, 7 Tage (Juli 2026):
    # Applebot 226.662 Aufrufe und zusammen 10,3 Stunden Serverzeit, Bytespider
    # 54.965, Googlebot 18.568, Python aiohttp 16.839, Baiduspider-render
    # 11.134 – mehr als Chrome und Firefox zusammen.
    #
    # robots.txt (Frontend-Repo) bremst die Crawler, die sich daran halten.
    # Bytespider und Skript-Clients tun das notorisch nicht, deshalb hier
    # zusätzlich eine Obergrenze pro IP.
    #
    # NICHT erfasst ist der grösste Einzelposten derselben Messung: 53.912
    # Aufrufe mit 12,7 Stunden Serverzeit kamen ganz ohne User-Agent, mehr als
    # von Applebot. Ein leerer String passt auf kein Muster, und eine Regel
    # „kein User-Agent, also drosseln" ist hier zu riskant: Der Prerender-Build
    # ruft die öffentliche API serverseitig auf und schickt je nach
    # Node-Version keine Kennung mit; er würde sich damit selbst ausbremsen und
    # der Produktions-Build abbrechen. Der Posten bleibt bewusst offen und
    # gehört gesondert angesehen.
    #
    # Das Limit ist bewusst großzügig: Es soll Ausbrüche kappen, nicht die
    # Indexierung verhindern – die öffentlichen Ligaseiten sollen gefunden
    # werden. Ein 429 ist für Suchmaschinen das dokumentierte Signal, langsamer
    # zu crawlen.
    #
    # Zur Einordnung der 60: Applebot kam über die Messwoche auf rund 22 Aufrufe
    # pro Minute. Das ist die Summe über alle seine Quell-IPs und über alle
    # Pfade, während hier je IP und nur auf GETs unter /api/ und /verband
    # gezählt wird. Die Zahl taugt also als Größenordnung, nicht als direkter
    # Vergleichswert – der tatsächliche Abstand zum Limit ist deutlich größer.
    #
    # Die Liste nennt die Crawler absichtlich namentlich statt pauschal /bot/i:
    # Ein pauschales Muster träfe auch Gerätekennungen wie „Cubot" und damit
    # echte Besucher.
    CRAWLER_USER_AGENTS = Regexp.union(
      /Applebot/i, /Googlebot/i, /GoogleOther/i, /Google-InspectionTool/i,
      /bingbot/i, /Bytespider/i, /Baiduspider/i, /YandexBot/i, /DuckDuckBot/i,
      /SeznamBot/i, /PetalBot/i,
      /AhrefsBot/i, /SemrushBot/i, /MJ12bot/i, /DotBot/i, /BLEXBot/i,
      /GPTBot/i, /ClaudeBot/i, /CCBot/i, /Amazonbot/i, /PerplexityBot/i,
      /meta-externalagent/i, /OAI-SearchBot/i, /ChatGPT-User/i,
      /facebookexternalhit/i, /Twitterbot/i,
      /python-urllib/i, /python-requests/i, /aiohttp/i, /Scrapy/i, %r{curl/}i, /Wget/i
    ).freeze

    # /verband liefert die Verbandslogos und wird ebenfalls an Rails
    # durchgereicht (nginx/config/saisonmanager.prod.conf). Ohne den Präfix
    # bliebe der Bildabruf ungezählt, ausgerechnet auf dem Pfad mit den
    # ActiveStorage-Anhängen.
    CRAWLER_THROTTLED_PATHS = %w[/api/ /verband].freeze

    # Datenquelle der Livestream-Overlays. Hat einen eigenen Topf weiter unten
    # und gehört nicht in die Crawler-Bremse: Eine Übertragung fragt im
    # Sekundentakt ab, und die eingebettete Chromium-Kennung von OBS steht heute
    # zwar nicht in CRAWLER_USER_AGENTS, ein künftig allgemeineres Muster in
    # dieser Liste würde aber mitten im Spiel die Anzeigetafel abwürgen.
    OVERLAY_PATH_PREFIX = '/api/v2/public/overlay'.freeze

    throttle('crawler/ip', limit: 60, period: 1.minute) do |req|
      # HEAD gehört dazu: Link-Prüfer und einige Crawler holen ausschließlich
      # Header, und teuer ist der Aufruf für den Server trotzdem. Schreibpfade
      # bleiben außen vor, Crawler stellen keine POSTs.
      next unless req.get? || req.head?
      next unless CRAWLER_THROTTLED_PATHS.any? { |p| req.path.start_with?(p) }
      next if req.path.start_with?(OVERLAY_PATH_PREFIX)
      # Wer angemeldet ist, soll sich nicht an einer falsch erkannten
      # Browser-Kennung ausbremsen. Geprüft wird nur, ob ein user_id-Cookie
      # anliegt, nicht dessen Signatur: Die ließe sich hier in der Middleware
      # nicht sinnvoll auflösen. Das heißt zugleich, dass ein beliebiges
      # user_id-Cookie genügt, um die Drosselung zu umgehen. Das ist
      # hingenommen – dies ist eine Kostenbremse gegen halbwegs kooperative
      # Crawler, keine Sicherheitsschranke gegen einen Angreifer.
      next if req.cookies.key?('user_id')
      # Wer einen Key mit eigener Grenze hat, wird von 'api/key' weiter unten
      # gezählt und gehört nicht zusätzlich in den IP-Topf. Sonst hinge ein
      # beantragter Zugang an zwei Grenzen: Die Kennungen, mit denen solche
      # Integrationen gebaut werden (python-requests, aiohttp, curl), stehen in
      # der Liste oben, und ein Anheben des Key-Limits durch die Verwaltung
      # bliebe wirkungslos, weil die 60 pro IP daneben stehen blieben. Die
      # Vereinbarung sagt eine Grenze je Key zu, nicht je Adresse.
      #
      # Keys OHNE eigene Grenze (eigenes Frontend, Prerender) bleiben bewusst im
      # IP-Topf: Der Frontend-Key steht im ausgelieferten Bundle und wäre sonst
      # der bequemste Weg, die Kostenbremse zu umgehen.
      next if ApiKey.cached_meta(req.get_header('HTTP_X_API_KEY'))&.[](:rate_limit)

      req.ip if CRAWLER_USER_AGENTS.match?(req.user_agent.to_s)
    end

    # Throttle requests by API key using each key's individual rate_limit (requests/minute).
    # Keys with rate_limit: nil are exempt (unlimited).
    #
    # Das Fallback im limit-Lambda ist kein Schmuck: rack-attack ruft erst den
    # Block unten (der auf ein gesetztes Limit prüft) und dann dieses Lambda auf.
    # Wird der Cache-Eintrag genau dazwischen verworfen – `clear_meta_cache`
    # feuert bei jedem Ändern und Löschen eines Keys –, käme hier nil an und der
    # Vergleich `count > nil` würde einen öffentlichen Request mit 500
    # beantworten statt mit 429.
    throttle('api/key',
             limit: lambda { |req|
               ApiKey.cached_meta(req.get_header('HTTP_X_API_KEY'))&.[](:rate_limit) || Float::INFINITY
             },
             period: 1.minute) do |req|
      raw_key = req.get_header('HTTP_X_API_KEY')
      next unless raw_key.present?
      next unless ApiKey.cached_meta(raw_key)&.[](:rate_limit)

      raw_key
    end

    # Grenze je Overlay-Token. Die Abrufe tragen keinen API-Key, fielen also
    # durch beide Töpfe oben hindurch.
    #
    # Rechnung: Overlay und Dock fragen im Sekundentakt, macht 120 pro Minute;
    # ein zweiter Regie-Rechner verdoppelt das. 300 lässt Luft für eine
    # zusätzliche Quelle und begrenzt zugleich, was ein weitergegebener Link
    # anrichten kann.
    #
    # Gezählt wird das Token, nicht die Adresse: In der Halle hängen alle
    # Rechner hinter derselben IP, und mehrere Übertragungen aus einem Verein
    # sollen sich nicht gegenseitig ausbremsen.
    throttle('overlay/token', limit: 300, period: 1.minute) do |req|
      next unless req.path.start_with?(OVERLAY_PATH_PREFIX)

      # Ausschließlich aus dem Query-String, nie aus `req.params`. Zwei Gründe:
      #
      # 1. `req.params` liest bei einem POST den Body. Rack::Attack sitzt
      #    unterhalb von ShowExceptions und außerhalb des Rettungsnetzes von
      #    ActionDispatch; ein zu großer Formular-Body endete dadurch in einem
      #    500 statt in einem sauberen 400.
      # 2. Bei `Content-Type: application/json` parst Rack den Body gar nicht.
      #    Das Token stünde dann nicht in `params`, der Block lieferte nil, und
      #    ausgerechnet der Schreibpfad bliebe ungedrosselt.
      #
      # Beide Clients hängen das Token an die URL, auch beim Schreiben.
      req.GET['token'].presence
    end

    # rack-attack übergibt dem Responder seit Version 6 ein Rack::Attack::Request
    # und nicht mehr das rohe env-Hash. Der Zugriff per env['...'] warf daher
    # NoMethodError und aus dem gedrosselten 429 wurde ein 500. Aufgefallen ist
    # das erst mit dem Test zum IP-Throttle oben: Der Key-Throttle hat in der
    # Praxis offenbar noch nie ausgelöst, sonst wäre es früher aufgeschlagen.
    self.throttled_responder = lambda do |request|
      match_data = request.env['rack.attack.match_data']
      now = match_data[:epoch_time]
      retry_after = match_data[:period] - (now % match_data[:period])

      [429,
       { 'Content-Type' => 'application/json', 'Retry-After' => retry_after.to_s },
       [{ error: 'Rate limit überschritten. Bitte später erneut versuchen.' }.to_json]]
    end
  end
end
