# Zeilenweises Einreichen eines Kursimports (#631).
#
# Bis hierher war die Datei die Einheit des Einreichens: `submit` lief ueber
# alle Zeilen, und die Vorpruefung blockierte die ganze Datei, sobald eine
# einzige Zeile unklar war. `deferred` stellt eine Zeile zurueck, damit die
# uebrigen laufen koennen.
#
# `submitted_at` ist dafuer die notwendige Ergaenzung und nicht bloss ein
# Zeitstempel fuer die Anzeige: Eine Zeile, die auf die LV-Freigabe wartet, und
# eine, die noch nie eingereicht wurde, stehen beide auf `pending_review`. Ohne
# das Merkmal je Zeile wuerde ein zweiter Submit die schon eingereichten Zeilen
# erneut anwenden, und die Freigabe-Warteschlange (bisher ueber
# `referee_course_imports.status`) koennte die zurueckgestellten Zeilen eines
# teilweise eingereichten Imports nicht von den wartenden trennen.
class AddDeferralToRefereeCourseResults < ActiveRecord::Migration[7.2]
  def up
    add_column :referee_course_results, :deferred, :boolean, default: false, null: false
    add_column :referee_course_results, :submitted_at, :datetime
    add_index :referee_course_results, :submitted_at

    # Backfill: Bestandszeilen tragen ihr Einreichungsdatum nicht, bisher galt
    # der Import-Status als Merkmal. Ohne diesen Lauf waere die
    # Freigabe-Warteschlange nach dem Deploy leer, weil `awaiting_lv_review`
    # jetzt `submitted_at` liest.
    execute <<~SQL.squish
      UPDATE referee_course_results r
      SET submitted_at = COALESCE(r.applied_at, r.reviewed_at, i.updated_at, r.updated_at)
      FROM referee_course_imports i
      WHERE i.id = r.referee_course_import_id
        AND i.status = 'submitted'
    SQL
  end

  def down
    remove_index :referee_course_results, :submitted_at
    remove_column :referee_course_results, :submitted_at
    remove_column :referee_course_results, :deferred
  end
end
