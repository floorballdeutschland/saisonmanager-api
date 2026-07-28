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
