module Rack
  class Attack
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
    # echte Client-IP und nicht die des Reverse Proxy.
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

    # Suchmaschinen und Skript-Clients stellen den größten Teil des Verkehrs auf
    # den öffentlichen Endpunkten. Messung Produktion, 7 Tage (Juli 2026):
    # Applebot 226.662 Aufrufe und zusammen 10,3 Stunden Serverzeit, Bytespider
    # 54.965, Googlebot 18.568, Python aiohttp 16.839, Baiduspider-render
    # 11.134 – mehr als Chrome und Firefox zusammen.
    #
    # robots.txt (Frontend-Repo) bremst die Crawler, die sich daran halten.
    # Bytespider und Skript-Clients tun das notorisch nicht, deshalb hier
    # zusätzlich eine harte Obergrenze pro IP.
    #
    # Das Limit ist bewusst großzügig: Es soll Ausbrüche kappen, nicht die
    # Indexierung verhindern – die öffentlichen Ligaseiten sollen gefunden
    # werden. 60 Aufrufe pro Minute liegen weit über dem gemessenen Mittel von
    # Applebot (rund 22 pro Minute), und ein 429 ist für Suchmaschinen das
    # dokumentierte Signal, langsamer zu crawlen.
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
      /facebookexternalhit/i, /Twitterbot/i,
      /python-urllib/i, /python-requests/i, /aiohttp/i, /Scrapy/i, %r{curl/}i, /Wget/i
    ).freeze

    throttle('crawler/ip', limit: 60, period: 1.minute) do |req|
      next unless req.get?
      next unless req.path.start_with?('/api/')
      # Angemeldete Sitzungen bleiben außen vor, damit eine falsch erkannte
      # Browser-Kennung niemandem die Arbeit im System ausbremst.
      next if req.get_header('HTTP_COOKIE').to_s.include?('user_id')

      req.ip if CRAWLER_USER_AGENTS.match?(req.user_agent.to_s)
    end

    # Throttle requests by API key using each key's individual rate_limit (requests/minute).
    # Keys with rate_limit: nil are exempt (unlimited).
    throttle('api/key',
             limit: ->(req) { ApiKey.cached_meta(req.get_header('HTTP_X_API_KEY'))&.[](:rate_limit) },
             period: 1.minute) do |req|
      raw_key = req.get_header('HTTP_X_API_KEY')
      next unless raw_key.present?
      next unless ApiKey.cached_meta(raw_key)&.[](:rate_limit)

      raw_key
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
