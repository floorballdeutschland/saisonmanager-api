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
# GELESEN wird aus beiden Spalten bisher nirgends. GESCHRIEBEN schon: Der
# Altdaten-Import 2010-2014 fuellt sie aus den alten Dumps
# (`LegacyImport::Transformer#club_attrs`, aufgerufen aus
# `lib/tasks/import_old_seasons.rake`), und `db/seeds.rb` setzt `city` fuer die
# Demovereine. Vereine, die der Altimport angelegt hat, tragen also bereits
# Ort und Postleitzahl -- unverifizierte Werte von 2010 bis 2014.
#
# Kein Backfill und kein Datenlauf, auch nicht in die andere Richtung: Diese
# Altwerte werden nicht geleert. Sie sind das Beste, was zu diesen Vereinen
# vorliegt, und wer die Anschrift ueber die Maske speichert, muss ohnehin alle
# acht Pflichtangaben stellen und sieht die beiden Felder dabei. Wo nichts
# steht, bleibt es leer und wird leer angezeigt.
#
# Vor dem Deploy einmal zaehlen, wie gross der Altbestand ist:
#   Club.active.where.not(city: [nil, '']).count
class AddStreetAndHouseNumberToClubs < ActiveRecord::Migration[7.2]
  def change
    add_column :clubs, :street, :string
    add_column :clubs, :house_number, :string
  end
end
