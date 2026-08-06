# Fassung der Nutzungsvereinbarung für die Saisonmanager-API und die Zahlen,
# die § 6 (Fair Use) nennt.
#
# Der Volltext liegt im Frontend (öffentliche Seite /api-zugang/nutzungsbedingungen),
# hier steht nur die Kennung der gültigen Fassung. Der Antrag speichert, welcher
# Fassung zugestimmt wurde; das Formular schickt sie mit und der Antrag wird
# abgelehnt, wenn sie nicht mehr aktuell ist (offener Tab über eine Änderung
# hinweg). Bei jeder inhaltlichen Änderung des Textes ist diese Konstante
# mitzuziehen, sonst dokumentiert der Antrag die falsche Fassung.
module ApiTerms
  VERSION = '2026-08-06'.freeze

  # Standardgrenze eines Zugangs aus dem Antragsprozess, in Anfragen pro Minute.
  # Sie wird technisch durchgesetzt (ApiKey#rate_limit, Throttle 'api/key' in
  # config/initializers/rack_attack.rb) und deshalb hier und nicht nur im
  # Vertragstext geführt: Der Wert, den § 6.1 nennt, ist derselbe, der beim
  # Abholen des Keys gesetzt wird.
  #
  # Zur Größenordnung: eine Anfrage je Sekunde im Mittel, im festen
  # Minutenfenster auch 60 am Stück. Eine Tabellen- oder Spielplanansicht
  # braucht pro Aufbau eine Handvoll Abrufe. Häufiger zu fragen bringt zudem
  # nichts, weil Antragskeys die Daten mit zehn Minuten Verzögerung bekommen
  # (realtime = false, § 6.3). Die Administration kann den Wert je Key
  # jederzeit anheben.
  RATE_LIMIT_PER_MINUTE = 60

  # Richtwert für das Tagesvolumen, den § 6.2 nennt. Bewusst NICHT technisch
  # durchgesetzt: Er dient der Einordnung und als Anlass für ein Gespräch, wenn
  # die Nutzungsstatistik (ApiKeyUsage, Ansicht in der Key-Verwaltung) deutlich
  # darüber liegt. Wer regelmäßig mehr braucht, spricht das vorher ab.
  DAILY_REQUEST_GUIDELINE = 10_000
end
