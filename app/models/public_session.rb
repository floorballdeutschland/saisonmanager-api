# Anonyme Sitzung der eigenen Website. Sie ersetzt den Frontend-API-Key, der
# im ausgelieferten Bundle stand: Wer ihn dort herauskopierte, bekam einen
# ungedrosselten Zugang mit allen Zusatzpaketen und umging damit den
# Antragsweg samt Nutzungsvereinbarung.
#
# Ein Geheimnis ist auch die Sitzung nicht, jeder Browser holt sich eine. Der
# Unterschied: Sie ist kurzlebig, wird einzeln gezählt und gedrosselt
# (config/initializers/rack_attack.rb), und ihr Ausstellen ist je Adresse
# begrenzt. Ein Skript bekommt damit nicht mehr als ein Besucher.
#
# Zustandslos: Das Cookie trägt eine zufällige Kennung und den
# Ausstellungszeitpunkt, signiert mit dem secret_key_base. Es gibt keine
# Tabelle, die Kennung dient nur als Zähler-Schlüssel im Throttle.
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
  # derselben IP. Wer einmal eine Sitzung hat, behält sie 24 Stunden; 60 neue
  # Besucher pro Minute aus einem Netz reichen auch für den Einlass.
  ISSUE_LIMIT_PER_MINUTE = 60

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

    # nil für fehlende, manipulierte oder abgelaufene Cookies.
    def verify(value)
      return nil if value.blank?

      data = verifier.verified(value, purpose: PURPOSE)
      return nil unless data.is_a?(Hash) && data['id'].is_a?(String) && data['iat'].is_a?(Integer)

      Payload.new(data['id'], Time.zone.at(data['iat']))
    rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
      nil
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

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end
  end
end
