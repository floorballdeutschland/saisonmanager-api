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

  # Der Aufruf aus der Middleware. Faellt die Datenbank aus, wird NICHT gesperrt:
  # Eine kaputte Sperrliste darf nicht den ganzen Betrieb abwuergen, und die
  # Sperre ist eine Aufraeummassnahme, keine Sicherheitsschranke.
  def self.blocked?(ip)
    return false if ip.blank?

    all_ips.include?(ip)
  rescue StandardError => e
    Rails.logger.error("BlockedIp.blocked? failed: #{e.class}: #{e.message}")
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

  def ip_parsable
    return if ip.blank?

    errors.add(:ip, 'ist keine gültige IP-Adresse') if parsed_ip.nil?
  end

  def ip_blockable
    addr = parsed_ip
    return if addr.nil?

    return unless UNBLOCKABLE.any? { |net| net.include?(addr) }

    errors.add(:ip, 'liegt im eigenen oder in einem privaten Netz und darf nicht gesperrt werden')
  end
end
