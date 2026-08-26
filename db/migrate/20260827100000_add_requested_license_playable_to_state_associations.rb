# Aufstellen darf bisher nur, wessen Lizenz erteilt ist: Der Kader-Dialog im
# Spielbericht blendet alles andere aus, solange es nicht schon in der
# Aufstellung steht (TeamLineupPlayerPipe im Frontend), und
# `GamesController#lineup_license_warning` meldet einen Spieler mit dem Status
# „beantragt" als nicht spielberechtigt.
#
# Für Landesverbände, deren Spielbetriebskommission erst nach dem Spieltag über
# die Anträge entscheidet, ist das zu streng: Dort gilt eine Person mit
# gestelltem Antrag bereits als einsetzbar. Der Schalter bleibt deshalb bewusst
# aus und wird je Landesverband gesetzt.
#
# Maßgeblich ist der Landesverband des Spielbetriebs der Liga (League#state_association),
# nicht der des Vereins: Die Zuständigkeit folgt der Liga, gleiche Wahl wie bei
# `scan_required` und der Expresslizenz.
#
# In INHERITED_SETTINGS aufgenommen, damit ein untergeordneter Landesverband die
# Regel seines Spielverbunds erbt, statt daneben eine eigene zu führen.
class AddRequestedLicensePlayableToStateAssociations < ActiveRecord::Migration[7.2]
  def change
    add_column :state_associations, :requested_license_playable, :boolean,
               default: false, null: false,
               comment: 'Wenn true: Spieler mit Lizenzstatus „beantragt“ duerfen im Spielbetrieb dieses Verbands aufgestellt werden'
  end
end
