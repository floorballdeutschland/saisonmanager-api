# frozen_string_literal: true

# Punkteschema einer Liga: wie viele Punkte ein Sieg, ein Unentschieden und ein
# Sieg beziehungsweise eine Niederlage nach Verlaengerung bringen. Ausgelagert
# aus League, weil die Klasse an der ClassLength-Grenze steht.
#
# Zwei Welten:
#
# * `legacy_league` (Altdaten-Importe): Das Wertungssystem des Altsystems
#   (`id_spielsystem`) liegt in `league_system_id`. 1 = 3-Punkte, 2 = 2-Punkte,
#   4 = "Anderes". System 2 fiel bis 08/2026 in denselben Sammelzweig wie 4 und
#   gab null Punkte fuer ein Unentschieden, was kein 2-Punkte-System ist.
#   Betroffen waren die vier bayerischen Jugendligen 2010/11 (Ligen 2029 bis
#   2032); Platzierungen verschieben sich dadurch keine, nur die Punktzahlen
#   stimmen wieder. System 4 bleibt bewusst im Sammelzweig, weil aus den
#   Altdaten nicht hervorgeht, was damit gemeint war (drei kurze Pokalrunden).
#   Ein leeres Feld faellt ebenfalls in den Sammelzweig: Die Importe der
#   Saisons 2 bis 5 haben es zeitweise gar nicht gesetzt, und `nil.to_i` ist 0.
#
# * alle uebrigen Ligen: `table_modus`, aktuell nur `classic` im Bestand.
module LeagueTablePoints
  extend ActiveSupport::Concern

  LEGACY_POINT_SYSTEMS = {
    1 => { won: 3, draw: 1, won_overtime: 2 },
    2 => { won: 2, draw: 1, won_overtime: 2 }
  }.freeze
  LEGACY_POINTS_FALLBACK = { won: 2, draw: 0, won_overtime: 0 }.freeze
  MODUS_POINTS = { 'classic' => { won: 3, draw: 1, won_overtime: 2 } }.freeze
  MODUS_POINTS_FALLBACK = { won: 10, draw: 1, won_overtime: 0 }.freeze

  def table_points
    if legacy_league
      LEGACY_POINT_SYSTEMS.fetch(league_system_id.to_i, LEGACY_POINTS_FALLBACK)
    else
      MODUS_POINTS.fetch(table_modus, MODUS_POINTS_FALLBACK)
    end
  end

  def won_points
    table_points[:won]
  end

  def draw_points
    table_points[:draw]
  end

  def won_overtime_points
    table_points[:won_overtime]
  end

  # Wer nach Verlaengerung verliert, behaelt den Punkt des Unentschiedens.
  def lost_overtime_points
    draw_points
  end
end
