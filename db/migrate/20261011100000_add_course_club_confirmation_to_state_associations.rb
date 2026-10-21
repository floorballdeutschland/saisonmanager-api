class AddCourseClubConfirmationToStateAssociations < ActiveRecord::Migration[7.2]
  def change
    add_column :state_associations, :course_club_confirmation_required, :boolean, default: false, null: false,
               comment: 'Schiri-Kurse: Selbstanmeldungen (Portal, oeffentlich) mit Verein als Zahler muss der ' \
                        'Verein bestaetigen, bevor sie einen Platz bekommen.'
  end
end
