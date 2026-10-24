# Ersatzweg für den Link zum Kalibrieren der Highlights (fe#560): Hat beim
# Beenden des Tabletmodus niemand einen Link angefordert, bekommen ihn die
# Vereinsmanager des Ausrichters (TabletHighlightLinks).
#
# - `stream_broadcasts.highlight_fallback_at`: wann der Wächter den Ersatzweg
#   für diese Übertragung geprüft hat, auch wenn es niemanden zum Anschreiben
#   gab. Die Anfragen selbst werden später gelöscht (PENDING_MAX_AGE,
#   EXPIRED_RETENTION); ohne den Vermerk ginge der Link danach erneut raus.
# - `tablet_highlight_requests.host_fallback`: die Anfrage stammt aus dem
#   Ersatzweg, nicht vom Tablet. Davon hängt nur der Text der Mail ab.
class AddHighlightFallbackToStreamBroadcasts < ActiveRecord::Migration[7.2]
  def change
    add_column :stream_broadcasts, :highlight_fallback_at, :datetime,
               comment: 'Ersatzweg Highlight-Link an den Ausrichter geprüft; NULL = noch nicht'
    add_column :tablet_highlight_requests, :host_fallback, :boolean,
               null: false, default: false, comment: 'Ersatzweg an den Ausrichter, nicht am Tablet angefordert'
  end
end
