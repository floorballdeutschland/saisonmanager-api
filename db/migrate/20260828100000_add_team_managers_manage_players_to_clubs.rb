# Anlegen, Deaktivieren und Reaktivieren von Spieler*innen liegen seit api#530
# ausnahmslos beim Vereinsmanager: Die Anlage schreibt eine
# Heimatmitgliedschaft, die Deaktivierung nimmt das Profil aus der
# Spielerliste des Vereins und aus der Auswahl beim Lizenzantrag. Beides ordnet
# den Bestand des Vereins und nicht die Aufstellung einer Mannschaft.
#
# Wer den Bestand tatsaechlich pflegt, ist aber eine Frage der Vereinsgroesse
# und nicht der Software: In einem Verein mit einer einzigen Mannschaft sind
# Vereins- und Teammanager oft dieselbe Person, in einem grossen Verein fuehrt
# jede Abteilung ihren eigenen Zugang. Statt die Regel fuer alle zu lockern
# oder fuer alle zu halten, entscheidet sie jetzt der Verein selbst.
#
# Bewusst aus: Fuer jeden Verein, der den Schalter nicht setzt, bleibt es beim
# heutigen Verhalten. Gesetzt wird er in der Vereinsverwaltung und dort nur von
# denen, die den Verein ohnehin verwalten (:update_own_club, also Admin, SBK
# und der Vereinsmanager selbst) -- der Teammanager kann sich das Recht nicht
# selbst erteilen.
class AddTeamManagersManagePlayersToClubs < ActiveRecord::Migration[7.2]
  def change
    add_column :clubs, :team_managers_manage_players, :boolean,
               default: false, null: false,
               comment: 'Wenn true: Teammanager dieses Vereins duerfen Spieler anlegen, deaktivieren und reaktivieren'
  end
end
