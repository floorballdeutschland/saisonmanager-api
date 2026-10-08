class AddCoachAssignmentEnabledToStateAssociations < ActiveRecord::Migration[7.2]
  def change
    add_column :state_associations, :coach_assignment_enabled, :boolean, default: false, null: false,
               comment: 'Reduzierter Ansetzungsmodus: die RSK setzt zusätzlich Schiedsrichtercoaches an. ' \
                        'Wirkt nur bei Hauptschalter an und Personenebene aus.'
  end
end
