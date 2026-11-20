# frozen_string_literal: true

# Anmeldeversuche je Benutzername, unabhaengig von der IP. Der IP-Topf
# 'login/ip' in config/initializers/rack_attack.rb laesst sich mit wechselnden
# Adressen umgehen, dieser Zaehler haengt am Konto. Nach LIMIT Versuchen nimmt
# das Konto bis zum Ende des Fensters keine Anmeldung mehr an, auch nicht mit
# dem richtigen Passwort: Sonst verriete die Antwort, wann das Raten getroffen
# hat.
#
# Erst zaehlen, dann pruefen: SessionsController ruft register_attempt VOR
# bcrypt auf, das atomare `increment` vergibt also jede Nummer genau einmal.
# Mit Lesen, Pruefen und erst danach Hochzaehlen liefen gebuendelt abgeschickte
# Anfragen alle am selben Zaehlerstand vorbei, es kaemen drei- bis viermal so
# viele Versuche durch. Eine gelungene Anmeldung loescht den Zaehler wieder;
# dasselbe tut ein erfolgreich gesetztes neues Passwort (UsersController), weil
# die Sperrmeldung genau dorthin verweist.
#
# Gezaehlt wird auch fuer unbekannte Namen und auf demselben Weg, damit das 429
# nicht verraet, ob es ein Konto gibt.
#
# Das Fenster beginnt mit dem ersten Versuch und wird nicht verlaengert: Der
# Redis-Store setzt die Ablaufzeit per `EXPIRE NX` nur, solange der Schluessel
# noch keine hat, und der MemoryStore uebernimmt beim Hochzaehlen die
# bestehende. Auch Versuche waehrend der Sperre schieben ihr Ende also nicht
# hinaus.
#
# Der Zaehler liegt im geteilten Rails.cache (Redis auf Prod). Ist der Cache
# nicht erreichbar, liefert `increment` nil, und die Grenze je Benutzername
# greift dann nicht; uebrig bleibt der IP-Topf. Das ist bewusst so: Eine
# ausgefallene Drossel soll niemanden aussperren. Der Preis der Sperre selbst:
# Wer einen Benutzernamen kennt, kann das Konto fuer WINDOW sperren.
class LoginFailureCounter
  LIMIT = 10
  WINDOW = 15.minutes

  def self.key(username)
    "login-failures/#{Digest::SHA256.hexdigest(username.to_s.downcase)}"
  end

  # Zaehlt einen Versuch und sagt, ob er noch zugelassen ist. Leere Namen
  # zaehlen nicht, User.login lehnt sie ohne bcrypt ab.
  def self.register_attempt(username)
    return true if username.blank?

    count = Rails.cache.increment(key(username), 1, expires_in: WINDOW)
    count.nil? || count <= LIMIT
  end

  def self.reset(username)
    return if username.blank?

    Rails.cache.delete(key(username))
  end
end
