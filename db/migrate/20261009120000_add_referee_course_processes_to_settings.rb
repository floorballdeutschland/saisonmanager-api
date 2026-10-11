class AddRefereeCourseProcessesToSettings < ActiveRecord::Migration[7.2]
  def change
    add_column :settings, :referee_course_processes, :jsonb, default: {}, null: false,
               comment: 'Schalter fuer die Kursprozesse: CSV-Import der Kursergebnisse und Kurse im System. ' \
                        'Leer heisst Vorgabe (Import an, Kurse aus), siehe Setting.referee_course_processes.'
  end
end
