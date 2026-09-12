# frozen_string_literal: true

# Riegel gegen die Kombination "mehrere Puma-Worker + prozesslokaler Cache".
#
# Diese Kombination ist still falsch, und das ist das Gefaehrliche daran: Die
# Anwendung startet, beantwortet Anfragen und faellt in keinem Test auf. Sie
# liefert lediglich falsche Zahlen. Rails.cache.delete raeumt bei einem
# prozesslokalen Store nur den Cache des Workers, der die Anfrage zufaellig
# bearbeitet hat; Game#flush_league_caches erreicht dann einen von vier
# Prozessen, und die uebrigen liefern bis zu fuenf Minuten alte Tabellen,
# Torschuetzenlisten und Spielstaende aus. Wer im Livebetrieb ein Tor eintraegt,
# sieht es bei jedem dritten Neuladen nicht.
#
# Der Zusammenhang ist an drei Stellen dokumentiert (config/puma.rb,
# config/environments/production.rb, Game#flush_league_caches), aber Dokumentation
# haelt niemanden davon ab, WEB_CONCURRENCY in der Umgebung zu setzen -- zumal
# Puma die Variable von sich aus liest (puma/configuration.rb, workers_env), also
# auch ohne Zutun von config/puma.rb clustert.
#
# Deshalb hier ein Abbruch beim Start statt einer stillen Fehlfunktion: Ein
# Container, der gar nicht erst hochkommt, faellt sofort auf. Falsche Tabellen
# auf der oeffentlichen Seite faellt erst jemandem im Verband auf, und dann ist
# unklar, woher sie kommen.
Rails.application.config.after_initialize do
  workers = ENV.fetch('WEB_CONCURRENCY', 0).to_i
  next unless workers > 1

  store = Rails.cache
  next unless store.is_a?(ActiveSupport::Cache::MemoryStore) ||
              store.is_a?(ActiveSupport::Cache::FileStore)

  raise <<~MESSAGE
    Puma laeuft mit #{workers} Workern, der Cache-Store ist aber
    #{store.class}.

    MemoryStore liegt je Prozess, FileStore ist ueber Prozessgrenzen hinweg
    nicht rennfrei (siehe den Kommentar in config/environments/production.rb).
    Beide machen Rails.cache.delete unzuverlaessig, sobald mehrere Worker
    laufen -- die Folge sind veraltete Tabellen und Spielstaende im
    Livebetrieb.

    Abhilfe: REDIS_URL setzen (dann waehlt production.rb den geteilten
    Redis-Cache), oder WEB_CONCURRENCY entfernen bzw. auf 1 setzen.
  MESSAGE
end
