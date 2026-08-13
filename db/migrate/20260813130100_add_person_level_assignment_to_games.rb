class AddPersonLevelAssignmentToGames < ActiveRecord::Migration[7.1]
  # Bisher stand die Markierung „durch Ansetzer*in ansetzen" als Sentinel-Text
  # 'Ansetzung durch RSK' *im* Freitextfeld nominated_referee_string. Damit
  # schlossen sich Markierung und Freitext gegenseitig aus – sobald die RSK
  # dasselbe Feld pflegt (Weg 3), geht das nicht mehr auf. Die Markierung wird
  # deshalb eine eigene Spalte, das Freitextfeld bleibt frei.
  MARKER = 'Ansetzung durch RSK'.freeze

  def up
    add_column :games, :person_level_assignment, :boolean, default: false, null: false

    # Bereits markierte Spiele übernehmen und den Sentinel aus dem Freitext
    # entfernen. Ohne den ersten Teil verschwinden sie aus der Ansetzer-Liste
    # (RefereeAssignmentsController#games filtert künftig auf das Flag), ohne den
    # zweiten stünde der Sentinel weiter öffentlich im Spielplan.
    execute <<~SQL.squish
      UPDATE games
         SET person_level_assignment = TRUE,
             nominated_referee_string = ''
       WHERE nominated_referee_string = #{quote(MARKER)}
    SQL
  end

  def down
    # Den Sentinel zurückschreiben, damit ein Rollback die Markierung nicht
    # verliert – aber nur, wo der Freitext frei ist. Weg-3-Einträge (Verein oder
    # Freitext) dürfen nicht überschrieben werden.
    execute <<~SQL.squish
      UPDATE games
         SET nominated_referee_string = #{quote(MARKER)}
       WHERE person_level_assignment = TRUE
         AND COALESCE(nominated_referee_string, '') = ''
    SQL

    remove_column :games, :person_level_assignment
  end
end
