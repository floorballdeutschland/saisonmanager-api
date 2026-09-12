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
# Deshalb hier ein Abbruch beim Start statt einer stillen Fehlfunktion.
#
# Was er NICHT leistet, damit sich niemand zu sicher fuehlt:
#   - Er liest nur ENV['WEB_CONCURRENCY']. Ein "puma -w 4" auf der
#     Kommandozeile oder ein hart gesetztes `workers` in config/puma.rb
#     erzeugen dieselbe kaputte Kombination und kommen durch.
#   - Er prueft die Store-KLASSE, nicht die Erreichbarkeit. Ein
#     RedisCacheStore, dessen Redis gar nicht laeuft, gilt ihm als in Ordnung
#     -- deshalb traegt rails-api in docker-compose.yml ein depends_on auf den
#     Redis-Container.
#   - Mit restart: unless-stopped ergibt der Abbruch ein Neustart-Karussell
#     statt einer einmaligen lauten Meldung. Sichtbar ist es trotzdem
#     ("Restarting" in docker ps), aber man muss hinsehen.
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
