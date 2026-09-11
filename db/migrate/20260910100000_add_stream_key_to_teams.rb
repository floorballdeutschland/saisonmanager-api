# frozen_string_literal: true

# Der YouTube-Streamschlüssel der Mannschaft.
#
# Bisher stand er in einer Excel-Datei der Spielbetriebskommission ("Übersicht
# Streams und Thumbnails", Blatt "Streamingkeys"), aus der die Livestreams von
# Hand über eine Zwischen-CSV bei YouTube angelegt wurden. Der Schlüssel gehört
# aber an die Mannschaft: Er entscheidet, auf welchen Kanal ein ausgerichteter
# Spieltag gesendet wird, und ohne ihn kann der Watchdog eine laufende
# Übertragung nicht dem Spiel zuordnen, das dort läuft.
#
# AN DER MANNSCHAFT, NICHT AM VEREIN: Im Bestand hat derselbe Verein je Liga
# einen anderen Schlüssel -- Floor Fighters Chemnitz sendet die 1. FBL Damen auf
# einen anderen Kanal als die 1. FBL Herren. Ein Feld am Verein könnte das nicht
# abbilden.
#
# BENUTZT WIRD ER ÜBER DEN AUSRICHTER, NICHT ÜBER DIE HEIMMANNSCHAFT. Gesendet
# wird aus der Halle, und wer die Halle stellt, stellt die Technik. Richtet ein
# Verein einen Spieltag mit mehreren Partien aus, laufen sie alle über seinen
# einen Schlüssel -- auch die, in denen er selbst nicht Heim ist. Ausrichter
# eines Spieltags ist `game_days.club_id`; zusammen mit `game_days.league_id`
# ergibt das die Mannschaft, an der der Schlüssel hängt -- ein Spielverbund
# richtet dabei über einen seiner Vereine aus. Eindeutig ist das nicht in jedem
# Fall (kein oder mehr als ein Treffer), und `GameDay#hosting_team` antwortet
# dann bewusst mit nil statt zu raten.
#
# BEWUSST OHNE EINDEUTIGKEITSPRÜFUNG: Der Schlüssel ist bei YouTube dauerhaft
# und überlebt die Saison, die Mannschaft nicht -- `teams` bekommt je Saison
# einen neuen Datensatz. Sobald die Ligakopie den Schlüssel mitnimmt, tragen die
# Mannschaft der alten und der neuen Saison denselben Wert, und ein Unique-Index
# würde genau die gewollte Übernahme blockieren. Die Auflösung Schlüssel →
# Mannschaft ist deshalb über das Datum eindeutig zu machen (nur eine der
# Mannschaften richtet heute aus), nicht über die Datenbank; siehe
# StreamWatchdog#spiel_fuer.
#
# Der Schlüssel ist ein Geheimnis: Wer ihn hat, sendet auf den Verbandskanal.
# Er darf in keiner öffentlichen Antwort auftauchen (siehe
# Team#serializable_hash).
class AddStreamKeyToTeams < ActiveRecord::Migration[7.2]
  def change
    add_column :teams, :stream_key, :string
    add_index :teams, :stream_key, where: 'stream_key IS NOT NULL'
  end
end
