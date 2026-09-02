class AddUniqueIndexToGameDayOverlayLinks < ActiveRecord::Migration[7.0]
  # Ein Overlay-Zugang gilt fuer genau EINEN Spieltag, und je Spieltag soll es
  # hoechstens einen geben: GameDayOverlayLink.generate! raeumt vor dem Anlegen
  # mit where(game_day:).destroy_all alles weg. Das Schema hielt diese Zusage
  # bisher nicht, es gab nur den nicht eindeutigen Index aus t.references.
  #
  # Ohne Riegel koennen zwei gleichzeitige Klicks (etwa im Spielbericht und in
  # der Sekretariats-Uebersicht) beide erst loeschen und dann anlegen, und es
  # bleiben ZWEI Zeilen stehen. Die Uebersicht liest sie mit index_by ein und
  # zeigt dann je nach Rueckgabereihenfolge einen beliebigen der beiden
  # Ersteller samt seinem Ablaufzeitpunkt -- und wer nachsieht, wem der Zugang
  # gehoert, bekommt womoeglich die falsche Auskunft.
  #
  # Kein partieller Index auf "noch gueltig": expires_at ist ein Zeitvergleich
  # und in einer Indexbedingung nicht erlaubt (nicht immutable). Der Riegel gilt
  # deshalb fuer alle Zeilen, was zur Bauart von generate! passt: Abgelaufene
  # Zeilen bleiben ohnehin nicht liegen, sie werden beim naechsten Erzeugen
  # geloescht.
  def up
    dedupe!

    remove_index :game_day_overlay_links, :game_day_id
    add_index :game_day_overlay_links, :game_day_id, unique: true
  end

  def down
    remove_index :game_day_overlay_links, :game_day_id
    add_index :game_day_overlay_links, :game_day_id
  end

  private

  # Der Bestand kann Duplikate enthalten, sonst liesse sich der Index nicht
  # anlegen. Es gewinnt der zuletzt erzeugte: Das ist der Zugang, dessen Token
  # der Verein zuletzt in die Hand bekommen hat.
  def dedupe!
    execute(<<~SQL.squish)
      DELETE FROM game_day_overlay_links
      WHERE id NOT IN (
        SELECT DISTINCT ON (game_day_id) id
        FROM game_day_overlay_links
        ORDER BY game_day_id, created_at DESC, id DESC
      )
    SQL
  end
end
