# frozen_string_literal: true

# Vorlagen für Titel und Beschreibung der YouTube-Übertragungen.
#
# Bisher baute eine Excel-Formel den Titel zusammen. Wer die Reihenfolge ändern
# wollte, musste die Formel anfassen -- und sie stand in genau einer Datei auf
# genau einem Rechner.
#
# IN DEN EINSTELLUNGEN UND NICHT IM BROWSER: Die Titel sind öffentlich und
# sollen einheitlich sein, unabhängig davon, wer von der Spielbetriebskommission
# den Knopf drückt. Im Browser-Speicher hätte jeder Rechner seine eigene
# Vorlage, und genau diesen Fehler macht die Excel-Formel gerade NICHT.
#
# Eine JSONB-Spalte für beide Vorlagen statt zweier Textspalten: Die nächste
# Angabe dieser Art (eine eigene Vorlage je Wettbewerb etwa, wie sie die
# Deutschen Meisterschaften bräuchten) käme sonst als dritte Spalte dazu.
class AddStreamTemplatesToSettings < ActiveRecord::Migration[7.2]
  def change
    add_column :settings, :stream_templates, :jsonb, default: {}
  end
end
