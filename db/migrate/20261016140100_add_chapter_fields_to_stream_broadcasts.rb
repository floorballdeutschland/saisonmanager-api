# Sprungmarken zu den Toren in der Beschreibung der Aufzeichnung (api#815).
#
# Start und Länge kommen einmal von YouTube und liegen dann hier: Die Positionen
# im Video werden bei jedem Lauf des Wächters neu gerechnet, ohne dafür
# Kontingent zu verbrauchen, und die Highlights lesen sie ohne Live-Abfrage.
class AddChapterFieldsToStreamBroadcasts < ActiveRecord::Migration[7.2]
  def change
    change_table :stream_broadcasts, bulk: true do |t|
      t.datetime :actual_start_at,
                 comment: 'liveStreamingDetails.actualStartTime: Sekunde 0 der Aufzeichnung'
      t.integer :vod_duration_seconds,
                comment: 'contentDetails.duration der Aufzeichnung in Sekunden (nicht actualEndTime)'
      t.string :chapters_digest,
               comment: 'SHA256 des zuletzt geschriebenen Markenblocks; gleich heißt: nichts zu schreiben'
      t.datetime :chapters_written_at
      t.datetime :chapters_checked_at,
                 comment: 'Letzte Nachrechnung nach Ablauf der Erstschreibfrist (einmal täglich)'
      t.integer :chapters_attempts, default: 0, null: false,
                                    comment: 'Fehlversuche für chapters_attempt_digest'
      t.string :chapters_attempt_digest
      t.datetime :chapters_failed_at,
                 comment: 'Endgültig gescheitert für chapters_attempt_digest; ein neuer Inhalt versucht es erneut'
    end
  end
end
