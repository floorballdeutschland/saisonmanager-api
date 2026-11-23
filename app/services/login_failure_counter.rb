# frozen_string_literal: true

# Anmeldeversuche je Benutzername, in zwei Toepfen. Der IP-Topf 'login/ip' in
# config/initializers/rack_attack.rb laesst sich mit wechselnden Adressen
# umgehen, diese Zaehler haengen am Konto.
#
# 1. Je Benutzername UND Netz (LIMIT Versuche in WINDOW): die eigentliche
#    Sperre gegen gezieltes Raten. Netz heisst die IPv4-Adresse bzw. das
#    IPv6-/64 (PublicSession.issuer_key, dieselbe Buendelung wie 'login/ip').
#    Bis 2.9.0 zaehlte hier nur der Name. Dann konnte eine einzige Adresse
#    neun bekannte Konten (Admins, SBK, ratbare `sr-nachname`-Konten)
#    dauerhaft aussperren, weil die Sperre nicht danach fragte, woher die
#    Versuche kamen. Jetzt sperrt sie nur das Netz des Angreifers fuer dieses
#    Konto; der Inhaber meldet sich von seinem eigenen Netz aus normal an.
#
# 2. Je Benutzername allein (NAME_LIMIT Versuche in NAME_WINDOW): Grenze gegen
#    verteiltes Raten aus vielen Netzen, die der erste Topf nicht sieht. Sie
#    sperrt das Konto ueberall, liegt deshalb weit hoeher.
#
#    In diesen Topf zaehlt nur, wer am ersten vorbeikommt. Sonst koennte ein
#    einzelnes Netz ihn doch wieder fuellen: 'login/ip' laesst je Adresse 360
#    Versuche in der Stunde zu, alle auf ein Konto gerichtet laege das Konto
#    nach gut acht Minuten ueberall fest. So bringt ein Netz je Konto hoechstens
#    vier volle Fenster zu je LIMIT in eine Stunde, also unter 50 (genauer:
#    ein angeschnittenes Fenster am Anfang und eins am Ende ergeben zusammen
#    hoechstens 49), und der Namenstopf bleibt verteilten Angriffen
#    vorbehalten.
#
# Ist einer der beiden Toepfe uebervoll, nimmt das Konto (bzw. das Konto von
# diesem Netz aus) bis zum Ende des Fensters keine Anmeldung mehr an, auch
# nicht mit dem richtigen Passwort: Sonst verriete die Antwort, wann das Raten
# getroffen hat. Welcher Topf griff, verraet die Antwort nicht.
#
# Erst zaehlen, dann pruefen: SessionsController ruft register_attempt VOR
# bcrypt auf, das atomare `increment` vergibt also jede Nummer genau einmal.
# Mit Lesen, Pruefen und erst danach Hochzaehlen liefen gebuendelt abgeschickte
# Anfragen alle am selben Zaehlerstand vorbei, es kaemen drei- bis viermal so
# viele Versuche durch.
#
# Eine gelungene Anmeldung loescht beide Toepfe: Sie beweist, dass der Inhaber
# am Werk ist, und er soll nach eigenen Vertippern nicht im Namenstopf
# weitergeschleppt werden. Der Preis: Ein verteilter Angreifer bekommt nach
# jeder Anmeldung des Inhabers wieder NAME_LIMIT frische Versuche. Ein ueber „Passwort vergessen" neu gesetztes
# Passwort (UsersController) loescht ebenfalls beide, siehe reset.
#
# Gezaehlt wird auch fuer unbekannte Namen und auf demselben Weg, damit das 429
# nicht verraet, ob es ein Konto gibt.
#
# Die Fenster beginnen mit dem ersten Versuch und werden nicht verlaengert: Der
# Redis-Store setzt die Ablaufzeit per `EXPIRE NX` nur, solange der Schluessel
# noch keine hat, und der MemoryStore uebernimmt beim Hochzaehlen die
# bestehende. Auch Versuche waehrend der Sperre schieben ihr Ende also nicht
# hinaus.
#
# Die Zaehler liegen im geteilten Rails.cache (Redis auf Prod). Ist der Cache
# nicht erreichbar, liefert `increment` nil, und der betroffene Topf greift
# nicht; uebrig bleibt der IP-Topf. Das ist bewusst so: Eine ausgefallene
# Drossel soll niemanden aussperren.
#
# Die Netzadresse steht nicht im Klartext im Cache, sondern zusammen mit dem
# Namen gehasht, wie der Name allein schon vorher.
class LoginFailureCounter
  # Je Benutzername und Netz.
  LIMIT = 10
  WINDOW = 15.minutes

  # Je Benutzername allein, gegen verteiltes Raten.
  NAME_LIMIT = 50
  NAME_WINDOW = 1.hour

  # Netz eines Clients: IPv4-Adresse oder IPv6-/64. `ip` muss dieselbe Quelle
  # sein wie `req.ip` in Rack::Attack, im Controller also `request.ip` (siehe
  # forwarded_priority in config/initializers/rack_attack.rb).
  def self.network(ip)
    ::PublicSession.issuer_key(ip)
  end

  def self.key(username, ip)
    digest = Digest::SHA256.hexdigest("#{username.to_s.downcase}\n#{network(ip)}")
    "login-failures/net/#{digest}"
  end

  def self.name_key(username)
    "login-failures/name/#{Digest::SHA256.hexdigest(username.to_s.downcase)}"
  end

  # Zaehlt einen Versuch und sagt, ob er noch zugelassen ist. Leere Namen
  # zaehlen nicht, User.login lehnt sie ohne bcrypt ab.
  def self.register_attempt(username, ip:)
    return true if username.blank?

    return false if over?(key(username, ip), LIMIT, WINDOW)

    # Erst nach bestandenem Netztopf, siehe Kopfkommentar.
    !over?(name_key(username), NAME_LIMIT, NAME_WINDOW)
  end

  # Loescht den Namenstopf und den Topf des Netzes, von dem aus `ip` kommt.
  #
  # Die Toepfe ANDERER Netze bleiben stehen. Aufzaehlen liessen sie sich nur
  # ueber `delete_matched`, und das nimmt im MemoryStore einen Regexp, im
  # Redis-Store ein Glob-Muster und durchsucht dort per SCAN den ganzen
  # Schluesselraum. Noetig ist es nicht: Wer das Passwort ueber den Link neu
  # setzt, tut das von seinem eigenen Netz aus und ist dort sofort frei, und
  # eine Sperre in einem fremden Netz trifft den Inhaber nicht und laeuft nach
  # WINDOW ab. Ohne `ip` bleibt es beim Namenstopf.
  def self.reset(username, ip: nil)
    return if username.blank?

    Rails.cache.delete(name_key(username))
    Rails.cache.delete(key(username, ip)) if ip
  end

  def self.over?(cache_key, limit, window)
    count = Rails.cache.increment(cache_key, 1, expires_in: window)
    !count.nil? && count > limit
  end
  private_class_method :over?
end
