class AddTeamInfoEditableDuringSeasonToStateAssociations < ActiveRecord::Migration[7.2]
  def change
    add_column :state_associations, :team_info_editable_during_season, :boolean,
               default: true, null: false,
               comment: 'Wenn true: Vereine duerfen Name, Kuerzel und Logo ihrer Mannschaften auch nach dem ersten Spieltag aendern'
  end
end
