# Merkt am Kurs-Ergebnis, dass die Lizenzmail an den Schiedsrichter noch
# aussteht.
#
# Hintergrund: `RefereeCourseResultApplier` schreibt die Lizenzfelder bereits
# beim Submit — auch bei Zeilen, die danach auf `pending_review` stehen bleiben.
# Die Mail soll bei diesen Zeilen aber erst rausgehen, wenn der Landesverband
# freigegeben hat. Beim Approve laufen dieselben Werte ein zweites Mal in
# `referee.update!`, verändern dort also nichts mehr — ohne diese Spalte wäre
# beim Approve nicht mehr zu erkennen, ob der Submit die Lizenz tatsächlich
# geändert hat oder ob sie schon vorher genau so dastand.
#
# Der Reject setzt die Spalte zurück: Eine zurückgewiesene Zeile löst keine Mail
# aus.
class AddLicenseNotificationPendingToRefereeCourseResults < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_results, :license_notification_pending,
               :boolean, default: false, null: false
  end
end
