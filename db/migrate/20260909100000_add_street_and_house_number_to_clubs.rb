# Rechnungsanschrift des Vereins (#641).
#
# Der abgebende Landesverband stellt bei einem Transfer eine Rechnung an den
# aufnehmenden Verein. Dafuer braucht er eine ladungsfaehige Anschrift, und die
# gab es bisher nirgends: Am Verein standen Name, Kuerzel, Name laut
# Vereinsregister, Bundesland und Kontakt-E-Mail.
#
# Nur zwei neue Spalten, weil `clubs.postcode` und `clubs.city` bereits
# existieren. Sie meinen genau das, was hier gebraucht wird -- zwei weitere
# Spalten daneben zu legen haette dauerhaft zwei Felder fuer dieselbe Frage im
# Schema hinterlassen.
#
# GELESEN wird aus beiden Spalten bisher nirgends -- die Anwendung zeigt Ort
# und Postleitzahl eines Vereins an keiner Stelle an. GESCHRIEBEN schon:
# `LegacyImport::Transformer#club_attrs` (aus `lib/tasks/import_old_seasons.rake`)
# und `db/seeds.rb`.
#
# Sie stehen deshalb nicht leer da. Produktion am 09.09.2026: 216 der 281
# aktiven Vereine tragen einen Ort, 217 eine Postleitzahl, 216 beides. Die
# Werte sind brauchbar -- Stichprobe und Formatpruefung: jede der 217
# Postleitzahlen ein sauberer Fuenfsteller, Postleitzahl und Ort passen
# zueinander, Ort und Bundesland zum Verein. Angelegt wurden sie mit der
# Datenuebernahme zum Systemstart (April bis Juni 2026), nicht in einem alten
# Import.
#
# Das ist die gute Nachricht fuer die Einfuehrung: Fuer diese 216 Vereine
# fehlen nur noch Strasse und Hausnummer, nicht die ganze Anschrift. Deshalb
# kein Backfill in die eine und kein Leeren in die andere Richtung -- wer die
# Maske speichert, muss ohnehin alle acht Pflichtangaben stellen und sieht Ort
# und Postleitzahl dabei, kann sie also im selben Zug bestaetigen oder
# richtigstellen. Bei den uebrigen 65 bleibt es leer und wird leer angezeigt.
class AddStreetAndHouseNumberToClubs < ActiveRecord::Migration[7.2]
  def change
    add_column :clubs, :street, :string
    add_column :clubs, :house_number, :string
  end
end
