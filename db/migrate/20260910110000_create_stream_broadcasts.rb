# frozen_string_literal: true

# Was der Watchdog über eine laufende YouTube-Übertragung weiß.
#
# Der Watchdog braucht ein Gedächtnis: "Seit wann liegt kein Signal mehr an?"
# lässt sich aus einem einzelnen Abruf nicht beantworten, YouTube liefert nur
# den Momentanwert (`streamStatus`). Die Vorlage aus dem Streaming-Ordner legte
# dafür eine JSON-Datei neben das Skript; in einem Container, der bei jedem
# Deploy neu gebaut wird, wäre die nach dem nächsten Release weg -- und mit ihr
# der Timer jeder gerade laufenden Übertragung.
#
# `game_id` ist bewusst optional. Eine Übertragung ohne zugeordnetes Spiel gibt
# es wirklich: die Deutschen Meisterschaften laufen als Tagesstream über den
# Schlüssel der ausrichtenden Halle, nicht über eine Mannschaft. Für die greift
# dann nur die Notabschaltung, nicht die Regel "Spielbericht geschlossen".
#
# Die Tabelle hält absichtlich NICHT den Streamschlüssel: Der steht schon an der
# Mannschaft, und ein Geheimnis an zwei Stellen ist eine Stelle zu viel. Die
# YouTube-eigene `stream_id` (die Ressourcen-ID, kein Geheimnis) reicht, um die
# Übertragung wiederzufinden.
class CreateStreamBroadcasts < ActiveRecord::Migration[7.2]
  def change
    create_table :stream_broadcasts do |t|
      t.string :broadcast_id, null: false
      t.string :stream_id
      t.bigint :game_id
      t.string :title
      # Wann zuletzt Signal anlag, und seit wann keines mehr. `signal_lost_at`
      # ist der Timer; ein Wert bedeutet "zählt gerade", nil bedeutet "Signal da".
      t.datetime :last_active_at
      t.datetime :signal_lost_at
      # Beendete Übertragungen bleiben stehen: Sie sind der Beleg dafür, warum
      # der Watchdog eingegriffen hat, und ohne sie stünde nach einem Fehlgriff
      # nur ein Logeintrag in einer Datei auf dem Server.
      t.datetime :ended_at
      t.string :ended_reason

      t.timestamps
    end

    add_index :stream_broadcasts, :broadcast_id, unique: true
    add_index :stream_broadcasts, :game_id
    add_index :stream_broadcasts, :ended_at
  end
end
