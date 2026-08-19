# Eine dauerhaft abgewiesene Adresse. Ausgewertet wird das in
# config/initializers/rack_attack.rb, vor dem Router — eine gesperrte Adresse
# beschaeftigt den Server also nicht mit Routing und Controllern.
#
# Wirksam ist das nur, weil `req.ip` nicht vom Client bestimmbar ist: nginx
# setzt X-Forwarded-For ueber $proxy_add_x_forwarded_for, haengt die echte
# Adresse also hinten an eine mitgeschickte Kette, und Rack nimmt daraus die
# letzte nicht vertraute Adresse.
class BlockedIp < ApplicationRecord
  # Wer wann welche Adresse gesperrt oder freigegeben hat, ist bei einer Sperre
  # die halbe Information. papertrail haelt auch die geloeschten Eintraege.
  has_paper_trail

  # Adressen, die NIE gesperrt werden duerfen. Ohne diesen Riegel nimmt ein
  # Tippfehler in der Maske die eigene Seite vom Netz: Gesperrt wird vor allem
  # anderen, es gibt also keine Ausnahme fuer das eigene Frontend, und wer sich
  # selbst aussperrt, kann die Sperre auch nicht mehr ueber die Maske loesen.
  #
  # Umfasst private Netze, Loopback und Link-Local. Der eigene Reverse Proxy
  # spricht Rails ueber das Docker-Netz an, liegt also in einem privaten Bereich
  # und ist damit mit abgedeckt.
  UNBLOCKABLE = [
    IPAddr.new('127.0.0.0/8'), IPAddr.new('::1/128'),
    IPAddr.new('10.0.0.0/8'), IPAddr.new('172.16.0.0/12'), IPAddr.new('192.168.0.0/16'),
    IPAddr.new('169.254.0.0/16'), IPAddr.new('fe80::/10'), IPAddr.new('fc00::/7')
  ].freeze

  CACHE_KEY = 'blocked_ips/all'.freeze

  # Sicherheitsnetz: Bleibt eine Invalidierung aus (etwa weil ein zweiter
  # Prozess seinen eigenen Speicher-Cache haelt), heilt sich die Liste von
  # selbst. Kurz genug, dass eine Freigabe zeitnah wirkt.
  CACHE_TTL = 2.minutes

  # Muss VOR den Validierungen laufen und laesst eine Bereichsangabe bewusst
  # stehen, damit ip_parsable sie noch sehen und ablehnen kann.
  before_validation :normalize_ip

  validates :ip, presence: true, uniqueness: { case_sensitive: false }
  validates :reason, presence: true, length: { maximum: 200 }
  validate :ip_parsable
  validate :ip_blockable

  after_commit :clear_cache

  # Liste der gesperrten Adressen, gecacht: Ausgewertet wird sie bei JEDER
  # Anfrage, eine Datenbankabfrage pro Request waere dafuer zu teuer.
  def self.all_ips
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { pluck(:ip).to_set }
  end

  # Der Aufruf aus der Middleware. Verglichen werden EXAKTE Adressen, keine Netze
  # — deshalb normalisiert normalize_ip beim Schreiben auf die Form, die req.ip
  # liefert, und deshalb lehnt ip_parsable Bereichsangaben ab.
  #
  # Faellt die Datenbank aus, wird NICHT gesperrt: Eine kaputte Sperrliste darf
  # nicht den ganzen Betrieb abwuergen, und die Sperre ist eine
  # Aufraeummassnahme, keine Sicherheitsschranke.
  def self.blocked?(ip)
    return false if ip.blank?

    all_ips.include?(ip)
  rescue StandardError => e
    # Auch an Sentry, wie ueberall sonst im Projekt: Ein Ausfall hier heisst
    # "die Sperre greift gerade nicht", und eine Logzeile allein geht in genau
    # dem Rauschen unter, dessen Eindaemmung der Anlass dieses Features war.
    Rails.logger.error("BlockedIp.blocked? failed: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    false
  end

  def self.clear_cache
    Rails.cache.delete(CACHE_KEY)
  end

  private

  def clear_cache
    self.class.clear_cache
  end

  # ArgumentError deckt beides ab: IPAddr::InvalidAddressError erbt davon
  # (ueber IPAddr::Error), und ein leerer oder unsinniger String kommt je nach
  # Eingabe als das eine oder das andere heraus.
  def parsed_ip
    IPAddr.new(ip.to_s)
  rescue ArgumentError
    nil
  end

  # Speichern in der Form, die `req.ip` zur Laufzeit liefert: klein geschrieben
  # und bei IPv6 komprimiert. Ohne das wird eine aus einem Log kopierte Adresse
  # wie `2001:DB8::1` gespeichert, sieht in der Tabelle richtig aus und trifft
  # nie — dieselbe Falle wie bei einer Bereichsangabe.
  #
  # Eine Angabe mit `/` bleibt unangetastet, damit ip_parsable sie ablehnen kann.
  # Wuerde hier normalisiert, verlore `82.165.87.0/24` still sein Praefix und
  # spaerrte nur noch eine einzige Adresse.
  def normalize_ip
    return if ip.blank? || ip.to_s.include?('/')

    addr = parsed_ip
    self.ip = addr.to_s if addr
  end

  def ip_parsable
    return if ip.blank?

    return errors.add(:ip, 'ist keine gültige IP-Adresse') if parsed_ip.nil?
    return unless ip.to_s.include?('/')

    # Ein Bereich liesse sich eintragen und wuerde NIE greifen: blocked?
    # vergleicht exakte Adressen. Ein Eintrag, der wie eine Sperre aussieht und
    # keine ist, ist der teuerste Zustand dieses Features — deshalb abweisen
    # statt stillschweigend annehmen.
    errors.add(:ip, 'muss eine einzelne Adresse sein, kein Bereich (kein „/")')
  end

  def ip_blockable
    addr = parsed_ip
    return if addr.nil?

    # Auch die IPv4-mapped Schreibweise pruefen: `::ffff:10.0.0.1` ist dieselbe
    # Adresse wie `10.0.0.1`, liegt aber in keinem der IPv4-Netze aus
    # UNBLOCKABLE. Ohne `native` liesse sich der Riegel per Schreibweise
    # umgehen.
    kandidaten = [addr]
    kandidaten << addr.native if addr.ipv4_mapped?

    return unless kandidaten.any? { |k| UNBLOCKABLE.any? { |net| net.include?(k) } }

    errors.add(:ip, 'liegt im eigenen oder in einem privaten Netz und darf nicht gesperrt werden')
  end

  # Falls hier je Bereiche erlaubt werden sollen (siehe ip_parsable), muss dieser
  # Riegel in BEIDE Richtungen pruefen. `IPAddr#include?` fragt nur, ob das
  # Argument IM Netz liegt: `0.0.0.0/0` umfasst die privaten Netze, liegt aber in
  # keinem davon und kaeme heute durch. Solange Bereiche abgewiesen werden, ist
  # das folgenlos — mit Netzvergleich in blocked? waere es ein Totalausfall ohne
  # Rueckweg ueber die Maske.
end
