# Der Nachname eines Spielerprofils wird in der Ausgabe von Spiel- und
# Statistikdaten weggelassen (DSGVO Art. 17/21: Antrag einer Person, die nicht
# mehr am Spielbetrieb teilnimmt und nicht laenger ueber eine Suche nach ihrem
# Namen auffindbar sein will).
#
# Welche Stufe das ist, und welche nicht:
#
# Stehen bleiben Vorname, Mannschaft, Spiele und Tore. Das erfuellt genau das,
# worum es im Antrag geht -- eine Suche nach "Vorname Nachname" findet eine
# Seite nicht mehr, auf der nur der Vorname steht -- und erhaelt zugleich eine
# lesbare Statistik. Es ist damit ausdruecklich eine PSEUDONYMISIERUNG und keine
# Anonymisierung: Innerhalb einer Liga mit ein paar Dutzend Beteiligten bleibt
# der Vorname zusammen mit Mannschaft und Saison fuer das Umfeld zuordenbar, es
# sind also weiterhin personenbezogene Daten. Wer eine schaerfere Stufe braucht,
# baut sie nicht in diesen Schalter hinein, sondern daneben: Der Datenbestand
# kennt genau einen Zustand, und der heisst "Nachname faellt weg".
#
# Keine Initiale: "Pierre L." waere in derselben Liga trivial
# zurueckzufuehren und wuerde den Antrag nicht erfuellen. Der Nachname faellt
# ersatzlos weg, die Anzeige zeigt dann den Vornamen allein.
#
# Warum die Anzeige und nicht der Datensatz geaendert wird:
#
# Die Namen in Scorerlisten, Aufstellungen und Spielberichten stammen
# ueberwiegend nicht aus `players`, sondern aus dem Spielbericht-Schnappschuss
# in `games.players` (`player_firstname` / `player_name`, siehe
# Game#lineup_player_names). Ein umbenanntes oder geloeschtes Spielerprofil
# aendert an diesen Seiten deshalb nichts -- der Nachname bliebe stehen.
# Umgekehrt ist der Schnappschuss der Nachweis darueber, wer laut Spielbericht
# auf dem Feld stand; ihn zu ueberschreiben waere nicht umkehrbar und wuerde den
# Bericht verfaelschen.
#
# Zwei Wege lesen den Namen doch aus dem Profil, und zwar absichtlich, damit eine
# Umbenennung dort sofort durchschlaegt: TeamsController#scorer_entries und der
# Rueckfall in League#scorer fuer Schnappschuesse ohne Namen (sehr alte
# Importe). Beide sind hier ebenfalls behandelt.
#
# Also bleibt der Bestand unangetastet und die Maskierung sitzt an den Stellen,
# die Namen herausgeben. Gesteuert wird sie ueber
# `players.public_last_name_hidden_at` und damit ueber die Spieler-ID -- die
# traegt jeder dieser Wege mit, auch der Schnappschuss.
#
# Bewusst nicht nach Anmeldung unterschieden: Der Nachname faellt in den Spiel-
# und Statistikdaten fuer jeden Abruf weg, auch fuer den angemeldeten und fuer
# das Spielsekretariat. Den vollen Namen fuehrt die Spielerverwaltung (Profil,
# Suche, Lizenzen, Sperren). Das ist die Grenze, die sich gegenueber der
# betroffenen Person begruenden laesst, und sie kommt ohne eine zweite, nur fuer
# angemeldete Abrufe gueltige Fassung jeder Nutzlast aus -- eine solche Fassung
# wuerde frueher oder spaeter in einen der gemeinsamen Caches geraten. Die
# Spieler-ID bleibt ueberall stehen, intern ist die Zuordnung damit weiter
# moeglich.
#
# AUSDRUECKLICH NICHT behandelt sind die Lizenzlisten am Spieltag:
# PublicLicenseListController, PublicSecretaryController und der Kader in
# ClubsController. Die tragen zwar "public" im Namen und kommen ohne Cookie aus,
# haengen aber an einem signierten Link beziehungsweise am Sekretariats-Token
# und dienen der Feststellung der Spielberechtigung am Kampfgericht. Dort muss
# die Person benennbar bleiben, sonst laesst sich nicht pruefen, wer spielen
# darf. Wer diese Stellen fuer eine Luecke haelt und zumacht, legt das
# Kampfgericht lahm.
module PublicPlayerNames
  # Der Nachname faellt ersatzlos weg, es tritt kein Platzhalter an seine
  # Stelle: Die oeffentlichen Ansichten setzen den Namen als "Vorname Nachname"
  # zusammen, ein leerer zweiter Teil ergibt dort den Vornamen allein. Ein Wort
  # wie "anonymisiert" stuende stattdessen als Nachname in jeder Zeile und
  # laese sich schlecht sortieren.
  HIDDEN_LAST_NAME = ''.freeze

  CACHE_KEY = 'players/public_last_name_hidden_ids'.freeze

  # Kurz gehalten, und das ist hier kein Geschmack: Die TTL ist nicht die
  # Ersparnis, sondern die Obergrenze des Schadens. Scheitert das Leeren beim
  # Umschalten (Redis weg, siehe #flush!), steht der Nachname genau so lange
  # weiter oeffentlich. Fuenf Minuten sind der Wert der uebrigen Liga-Caches,
  # und die Abfrage dahinter ist ein `pluck` auf einem Teilindex ueber eine
  # Handvoll Zeilen.
  CACHE_TTL = 5.minutes

  class << self
    # Menge statt Liste: Die Aufrufer schlagen je Aufstellungseintrag nach.
    #
    # Der Wert haelt sich fuer die Dauer der Anfrage in Current, weil die
    # Scorerliste einer Liga ihn je Spiel braucht. Ohne diesen Halt waeren das
    # so viele Redis-Zugriffe wie die Liga Spiele hat.
    def hidden_ids
      Current.public_last_name_hidden_ids ||= Array(cached_ids).to_set
    end

    def hidden?(player_id, hidden = hidden_ids)
      player_id.present? && hidden.include?(player_id.to_i)
    end

    # Eine ganze Aufstellungsseite aus dem Schnappschuss, fuer die Wege, die sie
    # roh herausgeben (die Schreibwege des Spielberichts in GamesController).
    def mask_lineup(entries, hidden = hidden_ids)
      return entries unless entries.is_a?(Array)

      entries.map { |entry| mask_lineup_entry(entry, hidden) }
    end

    # Ein einzelner Eintrag aus dem Spielbericht-Schnappschuss. Kopiert nur im
    # Trefferfall, damit der Regelfall ohne Allokation auskommt und der Aufrufer
    # weiter mit denselben Hash-Objekten arbeitet (Game#players_with_position
    # schreibt `position` hinein).
    #
    # `player_name` ist im Schnappschuss der NACHname, `player_firstname` der
    # Vorname. Angefasst wird nur der erste.
    def mask_lineup_entry(entry, hidden = hidden_ids)
      return entry unless entry.is_a?(Hash) && hidden?(entry['player_id'], hidden)

      entry.merge('player_name' => HIDDEN_LAST_NAME)
    end

    # Fuer die Wege, die den Namen aus dem Spielerdatensatz oder aus einem
    # bereits aufgeloesten Ergebnis nehmen (Scorerliste, Spielerstatistik,
    # Transferliste).
    def mask_names(player_id, first_name, last_name, hidden = hidden_ids)
      return [first_name, last_name] unless hidden?(player_id, hidden)

      [first_name, HIDDEN_LAST_NAME]
    end

    # Leert den Satz der anonymisierten IDs.
    #
    # `Rails.cache.delete` wirft nicht: Der `error_handler` des Redis-Stores
    # (config/environments/production.rb) verwandelt jeden Verbindungsfehler in
    # einen Rueckgabewert. Das unterscheidet zwei Faelle, die gleich aussehen:
    # `false` heisst "Schluessel war gar nicht da" und ist der Normalfall bei
    # kaltem Cache, `nil` heisst "Loeschung ist ausgefallen". Nur der zweite ist
    # meldenswert, denn dann steht der Klarname bis zum Ablauf von CACHE_TTL
    # weiter in Scorerliste, Aufstellung und Overlay, waehrend die
    # Geschaeftsstelle eine gruene Erfolgsmeldung sieht.
    def flush!
      Current.public_last_name_hidden_ids = nil
      result = Rails.cache.delete(CACHE_KEY)
      return unless result.nil?

      Sentry.capture_message(
        "PublicPlayerNames: #{CACHE_KEY} konnte nicht geleert werden, ein weggelassener " \
        "Nachname bleibt bis zu #{CACHE_TTL.inspect} oeffentlich sichtbar",
        level: :error
      )
    end

    # Nach dem Umschalten: die Caches, die bereits aufgeloeste Namen halten.
    #
    # `leagues/:id/scorer` ist der einzige Liga-Cache mit Namen (table und
    # schedule fuehren nur Mannschaften). `transfers` traegt die Namen der
    # Vereinswechsel dieser Saison. Die Spielerstatistik cacht nur Zahlen, der
    # Name im Kopf der Antwort wird frisch gelesen -- die beiden Schluessel
    # stehen hier nur, weil sie nichts kosten.
    #
    # Nicht geleert werden `games/:id/full_hash/*` und `games/:id/overlay/*`:
    # Beide tragen `updated_at` des Spiels im Schluessel, waeren also nur ueber
    # alle Spiele des Profils aufzuzaehlen, und ihre TTL betraegt eine Minute.
    #
    # `flush!` steht bewusst als erste Zeile: Platzt das Nachraeumen darunter,
    # greift die Maskierung trotzdem. Deshalb faengt der Rettungszweig auch nur
    # den Rest ab -- ein 500er an dieser Stelle wuerde einen erledigten Vorgang
    # als gescheitert melden, und der naechste Versuch antwortete dann mit
    # "ist bereits anonymisiert".
    def flush_for!(player)
      flush!

      season_id = Setting.current_season_id.to_i
      Rails.cache.delete("players/#{player.id}/stats/closed/#{season_id}")
      Rails.cache.delete("players/#{player.id}/stats/current/#{season_id}")
      Rails.cache.delete('transfers')

      # `referencing_player` vergleicht die Spieler-ID als Integer, waehrend die
      # Maskierung ueber `to_i` auch die als Zeichenkette abgelegten IDs des
      # Altbestands trifft. Ein solches Spiel faellt hier also aus der Liste:
      # gerendert wird richtig maskiert, nur der Scorer-Cache seiner Liga laeuft
      # ueber die TTL aus statt sofort. Das ist die billigere Seite der
      # Abweichung und kein Fehler.
      Game.referencing_player(player.id)
          .joins(game_day: :league)
          .distinct
          .pluck('leagues.id')
          .each { |league_id| Rails.cache.delete("leagues/#{league_id}/scorer") }
    rescue StandardError => e
      Sentry.capture_exception(e, level: :error, tags: { public_name_flush: 'partial' })
    end

    private

    def cached_ids
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        Player.public_last_name_hidden.pluck(:id)
      end
    end
  end
end
