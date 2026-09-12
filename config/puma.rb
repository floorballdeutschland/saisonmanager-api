# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 5 threads for minimum
# and maximum; this matches the default thread size of Active Record.
#
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
#
port        ENV.fetch("PORT") { 3040 }

# Specifies the `environment` that Puma will run in.
#
environment ENV.fetch("RAILS_ENV") { "development" }

# Specifies the `pidfile` that Puma will use.
pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

# Anzahl der Worker-Prozesse (clustered mode).
#
# Warum das ueberhaupt noetig ist: MRI-Ruby laesst wegen des GVL je Prozess
# nur einen Kern Ruby-Code ausfuehren. Die fuenf Threads oben helfen nur,
# solange auf die Datenbank gewartet wird -- sobald die Arbeit rechnen muss
# (Tabellen, Serialisierung, GC), stehen die Anfragen an. Am 1.
# Bundesliga-Spieltag (12.09.2026) stand der Prozess dauerhaft bei 100 %
# CPU, waehrend sieben der acht Kerne des Servers unbeschaeftigt waren.
#
# Standard ist bewusst 0, also unveraendert einprozessig: Das Umschalten
# gehoert in die Umgebung (WEB_CONCURRENCY in docker-compose.yml) und nicht
# in den Code, damit diese Datei fuer Entwicklung, Test und Produktion
# dieselbe bleibt.
#
# WICHTIG -- Vorbedingung: Mehrere Worker sind nur zusammen mit einem von
# allen Prozessen geteilten Cache zulaessig. Rails.cache.delete raeumt sonst
# nur den Cache des Workers auf, der die Anfrage zufaellig bearbeitet hat,
# und die uebrigen liefern bis zu fuenf Minuten alte Tabellen und
# Spielstaende aus (siehe Game#flush_league_caches). Deshalb waehlt
# config/environments/production.rb bei gesetztem REDIS_URL einen geteilten
# Redis-Cache. config/initializers/shared_cache_required.rb bricht den Start
# ab, falls doch einmal Worker und prozesslokaler Cache zusammenkommen --
# Puma liest WEB_CONCURRENCY naemlich auch von sich aus, unabhaengig von
# dieser Datei.
workers_count = ENV.fetch("WEB_CONCURRENCY") { 0 }.to_i

if workers_count.positive?
  workers workers_count

  # Anwendung vor dem Forken laden, damit die Worker sich den Speicher der
  # geladenen Klassen teilen (copy on write). Ohne preload_app! laedt jeder
  # Worker alles erneut.
  preload_app!

  # Bewusst KEIN on_worker_boot mit establish_connection. Das Idiom stammt aus
  # Rails 4 und ist hier gleich doppelt gegenstandslos: Der AR-Railtie leert
  # den Verbindungspool in after_initialize (active_record.clear_active_connections),
  # der Elternprozess haelt nach dem Boot also gar keine Verbindung, die
  # geerbt werden koennte. Und selbst wenn, verwirft
  # ActiveSupport::ForkTracker.after_fork die geerbten Pools von sich aus
  # (PoolConfig.discard_pools!), ohne die Sockets des Elternprozesses zu
  # schliessen. Die Rails-7-Vorlage fuer diese Datei enthaelt den Hook
  # folgerichtig nicht mehr. Ausserdem warnt Puma 8 bei on_worker_boot bereits
  # auf before_worker_boot -- ein Hook, der nichts tut, waere also nicht nur
  # nutzlos, sondern auch laut.
end

# Allow puma to be restarted by `rails restart` command.
plugin :tmp_restart
