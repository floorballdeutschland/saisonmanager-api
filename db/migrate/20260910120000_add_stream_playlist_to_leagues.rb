# frozen_string_literal: true

# Name der YouTube-Playlist, in die die Übertragungen dieser Liga einsortiert
# werden ("1. Floorball-Bundesliga Herren 26/27").
#
# Der Name und nicht die Playlist-ID: So steht er in der Excel-Vorlage der
# Spielbetriebskommission, so pflegt ihn ein Mensch, und die Anlage sucht die
# Playlist beim Erstellen ohnehin über ihren Namen (und legt sie an, wenn es sie
# noch nicht gibt) -- dasselbe Vorgehen wie im bisherigen Python-Skript. Eine ID
# wäre für jeden, der das Feld pflegt, eine undurchsichtige Zeichenkette.
#
# Er trägt die Saison, muss also jedes Jahr neu gesetzt werden. Das ist Absicht:
# Eine automatisch fortgeschriebene Playlist würde die Spiele zweier Spielzeiten
# in denselben Kanal-Ordner werfen, und das fiele erst Monate später auf.
#
# AN JEDER LIGA, NICHT NUR AN DEN BUNDESLIGEN. Leer heißt schlicht "keine
# Playlist" -- genau die Zeilen, die in der Vorlage "KEINE PLAYLIST" tragen. Eine
# Sonderregel nach Ligaklasse wäre Code, den irgendwann jemand suchen und ändern
# müsste, sobald ein weiterer Wettbewerb eine Playlist bekommt.
class AddStreamPlaylistToLeagues < ActiveRecord::Migration[7.2]
  def change
    add_column :leagues, :stream_playlist, :string
  end
end
