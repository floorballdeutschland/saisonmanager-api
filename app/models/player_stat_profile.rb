# Schnappschuss des laufenden Heimatvereins je Profil, geschrieben vom naechtlichen
# Lauf PlayerStats::Refresher.
#
# Einziger Zweck ist der Schalter „nur aktuell gemeldete Spieler" in der
# Spielerdaten-Ansicht: Er muss ein SQL-Filter bleiben, sonst leitet jeder Aufruf den
# Heimatverein fuer Zehntausende Profile in Ruby ab.
#
# WICHTIG: Diese Tabelle entscheidet NIE ueber Rechte. Sie ist eine Ableitung aus
# Player#home_club_entry und dabei bis zu einen Tag alt; Zustaendigkeit laeuft
# unveraendert ueber User#permission_hash und Club.home_clubs_of. Zwei sich
# widersprechende Leser des Heimatvereins gab es schon einmal (siehe den
# Kommentarblock an Player#home_club_entry), ein dritter mit Verzoegerung waere der
# naechste Vorfall.
class PlayerStatProfile < ApplicationRecord
  self.primary_key = 'player_id'

  belongs_to :player
end
