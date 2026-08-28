# Vereins- und Verbandsrangliste der Spielerdaten (Issue #465, Frontend #300).
#
# Gezaehlt wird, was eine Person fuer einen Verein gespielt hat: Einsaetze, Tore,
# Vorlagen und Strafminuten, saisonuebergreifend. Die Zahlen selbst gibt es laengst,
# nur nicht in dieser Richtung -- `PlayersController#stats_by_season` rechnet sie fuer
# EINEN Spieler aus allen beendeten Spielen zusammen und ruft dabei je Spiel
# `Game#evaluate_scorer`. Fuer einen ganzen Verein ist das ein Vielfaches davon, fuer
# einen Landesverband voellig aussichtslos.
#
# Ein Rails.cache-Eintrag loest das nicht: Der Store ist in Produktion :memory_store,
# also fluechtig und prozesslokal, und ueber eine fluechtige Struktur laesst sich weder
# serverseitig sortieren noch blaettern -- beides braucht eine Verbandsliste, die
# fuenfstellig viele Zeilen haben kann. Deshalb ein persistiertes Aggregat, das ein
# naechtlicher Lauf (rake player_stats:refresh) neu schreibt.
#
# Korn ist (Spieler, Liga, Team). Feiner waere (Spieler, Spiel) -- das waere ein
# Protokoll statt eines Aggregats und wuerde mit dem Spielbetrieb wachsen, ohne dass
# eine Ansicht die einzelne Zeile braucht. Groeber ginge nicht: Saison, Spielklasse und
# Spielbetrieb sind Filter der Ansicht und haengen an der Liga, der Verein am Team.
#
# Bewusst KEINE Anzeigenamen in der Tabelle. Name, Geschlecht und Deaktivierung kommen
# per Join frisch aus `players`, Liga- und Vereinsnamen frisch aus ihren Tabellen --
# dieselbe Regel, nach der `PlayersController#entry_with_names` die gecachten Werte
# anreichert. Sonst zeigt die Rangliste Umbenennungen bis zum naechsten Lauf falsch an.
class CreatePlayerGameStats < ActiveRecord::Migration[7.2]
  def change
    create_table :player_game_stats do |t|
      # index: false -- der Unique-Index unten beginnt mit player_id und deckt jede
      # Suche nach dem Profil bereits ab. Ein zweiter Index auf derselben Spalte waere
      # in einer Tabelle, die jede Nacht komplett neu geschrieben wird, nur
      # Schreibaufwand ohne Gegenwert.
      t.references :player, null: false, foreign_key: true, index: false
      # Ohne Fremdschluessel auf Liga und Team: beide werden geloescht
      # (League-Loeschung, cleanup:orphan_team_leagues), und eine Ranglisten-Zeile
      # darf das nicht blockieren. Verwaiste Zeilen raeumt der volle Lauf weg.
      t.bigint :team_id, null: false
      t.bigint :league_id, null: false
      t.bigint :club_id, null: false,
               comment: 'teams.club_id -- Spielgemeinschaften bleiben unberuecksichtigt (Vorgabe aus #465)'
      # Denormalisiert aus der Liga, damit Filter und Sortierung ohne Join laufen.
      # Jeder Lauf setzt die Werte neu, eine nachtraeglich korrigierte Ligaklasse
      # (leagues:renormalize_league_class_ids) wirkt also spaetestens am naechsten Tag.
      t.string :season_id, comment: 'leagues.season_id -- bewusst string wie dort, nie als Range filtern'
      t.integer :game_operation_id
      t.string :league_class_id
      t.integer :games, null: false, default: 0
      t.integer :goals, null: false, default: 0
      t.integer :assists, null: false, default: 0
      t.integer :penalty_minutes, null: false, default: 0
      # Kein created_at/updated_at: Die Tabelle wird liga-weise komplett neu
      # geschrieben, ein Zeitstempel je Zeile waere immer der des letzten Laufs.
      # Genau den traegt computed_at, und die Ansicht zeigt ihn als „Stand".
      t.datetime :computed_at, null: false
    end

    add_index :player_game_stats, %i[player_id league_id team_id], unique: true,
                                                                   name: 'index_player_game_stats_unique'
    add_index :player_game_stats, %i[club_id season_id]
    add_index :player_game_stats, %i[game_operation_id season_id]
    # Die Spielklasse ist Filter UND Auswahlliste der Ansicht; letztere ist ein
    # DISTINCT ueber die ganze Tabelle, sobald niemand auf einen Verein eingeschraenkt
    # ist. Ohne Index ist das garantiert ein sequentieller Durchlauf.
    add_index :player_game_stats, :league_class_id

    # Schnappschuss des laufenden Heimatvereins, eine Zeile pro Profil.
    #
    # Er traegt genau einen Schalter der Ansicht: „nur aktuell gemeldete Spieler"
    # (Standard an). Ohne ihn muesste jeder Aufruf den Heimatverein aus dem
    # players.clubs-JSONB in Ruby ableiten -- fuer eine Verbandsliste sind das
    # Zehntausende Profile pro Request. In SQL geht es nicht: `valid_until` ist
    # Freitext, ein ::date-Cast bricht am ersten abweichenden Format.
    #
    # WICHTIG: Diese Tabelle dient ausschliesslich der Listenauswahl und darf NIE
    # ueber Rechte entscheiden. Zwei sich widersprechende Leser des Heimatvereins gab
    # es schon einmal (`home_club` gegen die Fassung im Transferantrag, siehe den
    # Kommentarblock an Player#home_club_entry); ein dritter, der zusaetzlich einen
    # Tag alt ist, waere der naechste Vorfall. Zustaendigkeit laeuft weiter ueber
    # permission_hash und Club.home_clubs_of.
    create_table :player_stat_profiles, id: false do |t|
      t.bigint :player_id, null: false, primary_key: true
      t.bigint :home_club_id
      t.integer :home_game_operation_id
      t.datetime :computed_at, null: false
    end

    add_index :player_stat_profiles, :home_club_id
    add_index :player_stat_profiles, :home_game_operation_id
  end
end
