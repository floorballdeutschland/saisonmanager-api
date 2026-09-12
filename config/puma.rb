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
# Spielstaende aus (siehe Game#flush_league_caches). Deshalb steht in
# config/environments/production.rb ein file_store statt des frueheren
# memory_store. Wer hier Worker einschaltet, muss das dort pruefen.
workers_count = ENV.fetch("WEB_CONCURRENCY") { 0 }.to_i

if workers_count.positive?
  workers workers_count

  # Anwendung vor dem Forken laden, damit die Worker sich den Speicher der
  # geladenen Klassen teilen (copy on write). Ohne preload_app! laedt jeder
  # Worker alles erneut.
  preload_app!

  # Nach dem Fork braucht jeder Worker eine eigene Datenbankverbindung: Der
  # Elternprozess hat seine beim Laden geoeffnet, und ein geforkter Socket
  # darf nicht von mehreren Prozessen gleichzeitig benutzt werden.
  on_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord::Base)
  end
end

# Allow puma to be restarted by `rails restart` command.
plugin :tmp_restart
