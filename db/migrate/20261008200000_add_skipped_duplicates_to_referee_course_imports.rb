class AddSkippedDuplicatesToRefereeCourseImports < ActiveRecord::Migration[7.2]
  def change
    add_column :referee_course_imports, :skipped_duplicates, :jsonb, default: [], null: false,
               comment: 'Beim Upload uebersprungene Zeilen, die schon in einem frueheren Import ' \
                        'angewendet oder offen sind: [{lizenznummer, vorname, nachname, import_id}]'
  end
end
