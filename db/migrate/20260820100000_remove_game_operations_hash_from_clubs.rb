# Entfernt `clubs.game_operations_hash`.
#
# Die Spalte trug die Zuständigkeit für einen Verein als Heimat-Eintrag
# (`home_game_operation: true`) und, bis Release 1.78, zusätzlich Gast-Einträge
# auf fremde Spielbetriebe aus dem Altdaten-Import 2010–2014.
#
# Seit 1.90.0 leitet `Club#main_game_operation_id` die Zuständigkeit aus dem
# Landesverband ab. Die Spalte entscheidet damit über nichts mehr; sie blieb nur
# stehen, damit `clubs:responsibility_report` den Umzug gegenprüfen konnte. Der
# Datenlauf ist auf Staging und Produktion durch (Bericht: genau ein gewollter
# Wechsel, kein Verein ohne Zuständigkeit), der Bericht entfällt mit dieser
# Migration.
#
# Mit der Spalte verschwindet auch die Möglichkeit, einem Verein einen ZWEITEN
# Spielbetrieb zu geben. Die Gast-Einträge waren keine eigene Spalte, sondern
# weitere Objekte im selben Array, und eine Oberfläche zum Eintragen gab es nie.
# Nach dieser Migration ist ein zweiter Spielbetrieb strukturell nicht mehr
# darstellbar. Wer fremde Vereine lesen muss, bekommt eine Vereins-Freigabe
# (StateAssociationRelease); wer eine Gastmannschaft betreut, ist über die Liga
# zuständig.
#
# Irreversibel: Der Inhalt ließe sich aus dem Landesverband zwar wieder
# herstellen, aber nur in der Form, die diese Umstellung gerade beseitigt hat –
# ein `down`, das die Altlast neu erzeugt, wäre schlimmer als keins.
#
# WAS DAS FÜR EINEN ROLLBACK BEDEUTET
#
# `rails db:rollback` ist ab hier tot: Diese Migration ist die jüngste, `STEP=1`
# trifft also zuerst sie und wirft, bevor irgendetwas anderes zurückgeht. Wer
# eine ältere Migration zurücknehmen muss, gibt `VERSION` ausdrücklich an.
#
# Ein Rollback des CODES auf 1.90.0 ist dagegen unkritisch: Dort gibt es den
# Leser `Club#game_operations_hash` noch, aber ausser dem entfallenen Rake-Task
# ruft ihn niemand auf. Ein Rollback über 1.90.0 hinaus ist unbrauchbar, weil der
# Code davor die Spalte in SQL-Bedingungen liest; das endet in lauten 500ern,
# nicht in stillen Fehlern.
class RemoveGameOperationsHashFromClubs < ActiveRecord::Migration[7.2]
  def up
    # Den ausgehenden Inhalt ins Deploy-Log schreiben, bevor er weg ist, wie in
    # 20260817100000. Der Datenlauf ist am 20.08.2026 gelaufen und dokumentiert,
    # aber die Werte je Verein sind danach nur noch aus einem Datenbank-Abzug zu
    # holen. Fragt drei Wochen später ein Verband, warum er einen Verein früher
    # gesehen hat, ist diese Zeile die Antwort.
    belegte = select_all(<<~SQL.squish).to_a
      SELECT id, game_operations_hash::text AS eintrag
      FROM clubs
      WHERE game_operations_hash IS NOT NULL
        AND game_operations_hash::text NOT IN ('[]', 'null')
      ORDER BY id
    SQL
    say "game_operations_hash vor dem Entfernen, #{belegte.size} belegte Zeile(n):"
    belegte.each { |zeile| say "  Verein #{zeile['id']}: #{zeile['eintrag']}", true }

    remove_column :clubs, :game_operations_hash

    # Wie in 20260817100000: Läuft in demselben `db:migrate` später eine
    # Migration, die einen Club schreibt, hätte sie sonst die Spalte noch im
    # Attributsatz.
    Club.reset_column_information
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
