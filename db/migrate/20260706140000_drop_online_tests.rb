class DropOnlineTests < ActiveRecord::Migration[7.1]
  # Die Online-Prüfungen-Funktion (Schiris legen Tests im Saisonmanager selbst
  # ab) wird nicht mehr angeboten; Prüfungsergebnisse kommen ausschließlich
  # noch über den CSV-Kurs-Import (referee_course_imports/_results). Der Menü-
  # punkt war seit Kurzem nach Einführung bereits ausgeblendet, es gibt keine
  # produktiven Testdaten. Irreversibel by design – kein Down-Pfad, da die
  # zugehörigen Models/Controller ebenfalls entfernt wurden.
  def up
    drop_table :online_test_attempts
    drop_table :online_test_assignments
    drop_table :online_test_questions
    drop_table :online_tests
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
