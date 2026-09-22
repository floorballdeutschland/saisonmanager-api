# Anonymisierung einzelner Spielerprofile in der Ausgabe von Spiel- und
# Statistikdaten (DSGVO Art. 17/21: Antrag auf Loeschung der oeffentlich
# zugaenglichen Daten einer Person, die nicht mehr am Spielbetrieb teilnimmt).
#
# Warum die Anzeige und nicht der Datensatz geaendert wird:
#
# Die Namen in Scorerlisten, Aufstellungen und Spielberichten stammen NICHT aus
# `players`, sondern aus dem Spielbericht-Schnappschuss in `games.players`
# (`player_firstname` / `player_name`, siehe Game#lineup_player_names). Ein
# umbenanntes oder geloeschtes Spielerprofil aendert an den oeffentlichen Seiten
# deshalb nichts -- der Name bliebe stehen. Umgekehrt ist der Schnappschuss der
# Nachweis darueber, wer laut Spielbericht auf dem Feld stand; ihn zu
# ueberschreiben waere nicht umkehrbar und wuerde den Bericht verfaelschen.
#
# Also bleibt der Bestand unangetastet und die Maskierung sitzt an den Stellen,
# die Namen herausgeben. Gesteuert wird sie ueber `players.public_name_hidden_at`
# und damit ueber die Spieler-ID -- die traegt jeder dieser Wege mit, auch der
# Schnappschuss.
#
# Bewusst nicht nach Anmeldung unterschieden: Maskiert werden die Spiel- und
# Statistikdaten fuer jeden Abruf, den vollen Namen fuehrt allein die
# Spielerverwaltung (Profil, Suche, Lizenzen, Sperren). Das ist die Grenze, die
# sich gegenueber der betroffenen Person begruenden laesst, und sie kommt ohne
# zweite, nur fuer angemeldete Abrufe gueltige Fassung jeder Nutzlast aus --
# eine solche Fassung wuerde frueher oder spaeter in einen der gemeinsamen
# Caches geraten. Die Spieler-ID bleibt ueberall stehen, intern ist die Zuordnung
# damit weiter moeglich.
#
# Keine Initialen und kein Namensrest: In einer Liga mit ein paar Dutzend
# Beteiligten waere "P. Labuch" oder "Pierre L." trivial zurueckzufuehren und
# wuerde den Antrag nicht erfuellen.
module PublicPlayerNames
  HIDDEN_FIRST_NAME = ''.freeze
  HIDDEN_LAST_NAME = 'Anonymisiert'.freeze

  # Die Menge ist klein (Einzelfaelle) und wird auf jeder oeffentlichen
  # Spielseite gebraucht, deshalb gecacht. Geleert wird beim Umschalten
  # (Player#hide_public_name!), die TTL ist nur die zweite Sicherung.
  CACHE_KEY = 'players/public_name_hidden_ids'.freeze
  CACHE_TTL = 1.hour

  class << self
    # Menge statt Liste: Die Aufrufer schlagen je Aufstellungseintrag nach.
    def hidden_ids
      Array(cached_ids).to_set
    end

    def hidden?(player_id, hidden = hidden_ids)
      player_id.present? && hidden.include?(player_id.to_i)
    end

    # Eine Aufstellungsliste aus dem Spielbericht-Schnappschuss.
    #
    # Ohne betroffenen Spieler kommt die Liste unveraendert zurueck, inklusive
    # der urspruenglichen Hash-Objekte: Game#players_with_position schreibt in
    # die Eintraege (`position`) und verlaesst sich darauf, dass es dieselben
    # sind.
    def mask_lineup(entries, hidden = hidden_ids)
      return entries if hidden.empty? || !entries.is_a?(Array)

      entries.map { |entry| mask_lineup_entry(entry, hidden) }
    end

    # Ein einzelner Schnappschuss-Eintrag. Kopiert nur im Trefferfall, damit der
    # Regelfall ohne Allokation auskommt.
    def mask_lineup_entry(entry, hidden = hidden_ids)
      return entry unless entry.is_a?(Hash) && hidden?(entry['player_id'], hidden)

      entry.merge('player_firstname' => HIDDEN_FIRST_NAME, 'player_name' => HIDDEN_LAST_NAME)
    end

    # Fuer die Wege, die den Namen aus dem Spielerdatensatz oder aus einem
    # bereits aufgeloesten Ergebnis nehmen (Scorerliste, Spielerstatistik).
    def mask_names(player_id, first_name, last_name, hidden = hidden_ids)
      return [first_name, last_name] unless hidden?(player_id, hidden)

      [HIDDEN_FIRST_NAME, HIDDEN_LAST_NAME]
    end

    def flush!
      Rails.cache.delete(CACHE_KEY)
    end

    # Nach dem Umschalten: die Caches, die bereits aufgeloeste Namen halten.
    #
    # `leagues/:id/scorer` ist der einzige Liga-Cache mit Namen (table und
    # schedule fuehren nur Mannschaften). Die Spielerstatistik cacht zwar nur
    # Zahlen, der Kopf der Antwort traegt aber den Namen -- er wird frisch
    # gelesen, deshalb reicht dort der Eintrag des Spielers selbst nicht, er ist
    # gar nicht betroffen. Er steht hier trotzdem, weil die Liste der Ligen aus
    # derselben Abfrage faellt und ein Eintrag zu wenig teurer waere als einer
    # zu viel.
    #
    # `games/:id/full_hash/*` bleibt aussen vor: Der Key traegt `updated_at` des
    # Spiels, liesse sich also nur ueber alle Spiele des Profils aufzaehlen, und
    # die TTL betraegt dort eine Minute.
    def flush_for!(player)
      flush!

      season_id = Setting.current_season_id.to_i
      Rails.cache.delete("players/#{player.id}/stats/closed/#{season_id}")
      Rails.cache.delete("players/#{player.id}/stats/current/#{season_id}")

      Game.referencing_player(player.id)
          .joins(game_day: :league)
          .distinct
          .pluck('leagues.id')
          .each { |league_id| Rails.cache.delete("leagues/#{league_id}/scorer") }
    end

    private

    def cached_ids
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        Player.where.not(public_name_hidden_at: nil).pluck(:id)
      end
    end
  end
end
