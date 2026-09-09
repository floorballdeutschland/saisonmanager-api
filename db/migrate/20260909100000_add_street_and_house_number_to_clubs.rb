# Rechnungsanschrift des Vereins (#641).
#
# Der abgebende Landesverband stellt bei einem Transfer eine Rechnung an den
# aufnehmenden Verein. Dafuer braucht er eine ladungsfaehige Anschrift, und die
# gab es bisher nirgends: Am Verein standen Name, Kuerzel, Name laut
# Vereinsregister, Bundesland und Kontakt-E-Mail.
#
# Nur zwei neue Spalten, weil `clubs.postcode` und `clubs.city` bereits
# existieren. Beide stammen aus der Anfangszeit und werden seither von keiner
# Zeile Anwendungscode gelesen oder geschrieben (Stand 09.09.2026: kein Treffer
# in app/ und lib/ ausser der Postleitzahlen-Tabelle in ApplicationRecord, die
# zu Spielorten gehoert). Sie meinen genau das, was hier gebraucht wird --
# zwei weitere Spalten daneben zu legen haette dauerhaft zwei Felder fuer
# dieselbe Frage im Schema hinterlassen.
#
# Kein Backfill und kein Datenlauf: Wo nichts gepflegt ist, bleibt es leer und
# wird leer angezeigt. Die Landesverbaende tragen es selbst nach, sobald sie
# die Felder sehen.
class AddStreetAndHouseNumberToClubs < ActiveRecord::Migration[7.2]
  def change
    add_column :clubs, :street, :string
    add_column :clubs, :house_number, :string
  end
end
