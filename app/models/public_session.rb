# Anonyme Sitzung der eigenen Website. Sie ersetzt den Frontend-API-Key, der
# im ausgelieferten Bundle stand: Wer ihn dort herauskopierte, bekam einen
# ungedrosselten Zugang mit allen Zusatzpaketen und umging damit den
# Antragsweg samt Nutzungsvereinbarung.
#
# Ein Geheimnis ist auch die Sitzung nicht, jeder Browser holt sich eine. Der
# Unterschied: Sie ist kurzlebig, wird einzeln gezählt und gedrosselt
# (config/initializers/rack_attack.rb), und ihr Ausstellen ist je Adresse
# begrenzt. Ein Skript, das seine Sitzung behält, bekommt damit nicht mehr als
# ein Besucher; wer laufend neue holt, stößt an die Grenzen je Adresse. Gegen
# einen entschlossenen Nachbau mit vielen Adressen hilft das nicht, öffentliche
# Daten lassen sich technisch nicht exklusiv halten.
#
# Zustandslos: Das Cookie trägt eine zufällige Kennung und den
# Ausstellungszeitpunkt, signiert mit dem secret_key_base. Es gibt keine
# Tabelle; die Kennung dient als Zähler-Schlüssel im Throttle und, gekürzt,
# in der Logzeile `public-access`.
class PublicSession
  COOKIE_NAME = 'sm_public_session'.freeze

  # Laufzeit eines Cookies. Nach RENEW_AFTER wird es bei der nächsten Anfrage
  # still erneuert, wer die Seite offen hat, merkt vom Ablauf also nichts.
  TTL = 24.hours
  RENEW_AFTER = 12.hours

  # Anfragen je Sitzung und Minute. Die öffentlichen Seiten fragen im
  # 30-Sekunden-Takt nach, ein Seitenwechsel löst eine Handvoll Abrufe aus.
  # 300 lässt mehreren offenen Tabs und schnellem Klicken reichlich Luft.
  RATE_LIMIT_PER_MINUTE = 300

  # Neue Sitzungen je Adresse und Minute. Gezählt wird bewusst nur das
  # Ausstellen und nicht jeder Abruf: In der Halle hängen alle Zuschauer hinter
  # derselben IP. Wer einmal eine Sitzung hat, behält sie 24 Stunden.
  #
  # 300 und nicht weniger, weil bei einem Finale mit über tausend Zuschauern
  # kurz vor dem Anpfiff viele Geräte im Hallen-WLAN zugleich zum ersten Mal
  # kommen. Wer doch an die Grenze stößt, wartet im Frontend still ab
  # (PublicSessionService) und bekommt erst eine Meldung, wenn auch mehrere
  # Minuten Warten nicht reichen.
  ISSUE_LIMIT_PER_MINUTE = 300

  # Neue Sitzungen je Adresse und Stunde. Jedes Gerät holt höchstens eine
  # Sitzung am Tag, eine Halle mit weit über tausend Zuschauern bleibt also
  # darunter. Ein Skript, das Sitzungen wechselt, um die Grenze je Sitzung zu
  # umgehen, ist damit nach wenigen Minuten gedeckelt.
  ISSUE_LIMIT_PER_HOUR = 2000

  PURPOSE = :public_session

  Payload = Struct.new(:id, :issued_at) do
    def renew?(now = Time.current)
      issued_at <= now - RENEW_AFTER
    end
  end

  class << self
    # Liefert [cookie_value, payload]. Mit `id` wird eine bestehende Sitzung
    # verlängert, sie behält dann ihre Kennung und damit ihren Throttle-Zähler.
    def issue(id: SecureRandom.hex(16), now: Time.current)
      value = verifier.generate({ 'id' => id, 'iat' => now.to_i }, expires_in: TTL, purpose: PURPOSE)
      [value, Payload.new(id, Time.zone.at(now.to_i))]
    end

    # nil für fehlende, manipulierte oder abgelaufene Cookies. `verified`
    # liefert in diesen Fällen selbst nil, ohne zu werfen.
    #
    # Eine gültige Signatur mit unerwartetem Inhalt ist dagegen nie ein
    # Besucherfall, sondern ein Fehler bei uns (etwa ein geänderter
    # Serializer). Dann gälte jede Sitzung als ungültig, die Website bliebe
    # leer und die Drossel je Sitzung zählte nichts mehr; deshalb gemeldet.
    def verify(value)
      return nil if value.blank?

      data = verifier.verified(value, purpose: PURPOSE)
      return nil if data.nil?

      unless data.is_a?(Hash) && data['id'].is_a?(String) && data['iat'].is_a?(Integer)
        report_unexpected("PublicSession: signiertes Cookie mit unerwartetem Inhalt (#{data.class})")
        return nil
      end

      Payload.new(data['id'], Time.zone.at(data['iat']))
    rescue ArgumentError => e
      report_unexpected("PublicSession: Cookie nicht lesbar: #{e.class}: #{e.message}")
      nil
    end

    # Schlüssel für die Ausstellungs-Töpfe. IPv6 wird je /64 gebündelt: Ein
    # Anschluss bekommt ein ganzes /64, und jede Adresse daraus einzeln zu
    # zählen, gäbe einem Skript beliebig viele Töpfe.
    def issuer_key(ip)
      addr = IPAddr.new(ip.to_s)
      addr.ipv6? ? "#{addr.mask(64)}/64" : addr.to_s
    rescue IPAddr::InvalidAddressError
      ip.to_s
    end

    # Attribute für cookies[...] im Controller. `secure` nur in production
    # (das umfasst Staging), lokal läuft die API über http.
    def cookie_options(value)
      {
        value: value,
        expires: TTL.from_now,
        httponly: true,
        same_site: :strict,
        secure: Rails.env.production?
      }
    end

    private

    def report_unexpected(message)
      Rails.logger.warn(message)
      Sentry.capture_message(message) if defined?(Sentry)
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end
  end
end
