class AddSeasonIdToStateAssociationReleases < ActiveRecord::Migration[7.0]
  def up
    add_column :state_association_releases, :season_id, :integer

    current_season_id = Setting.current.systems.dig('1', 'current_season_id')
    StateAssociationRelease.reset_column_information
    StateAssociationRelease.where(season_id: nil).update_all(season_id: current_season_id) if current_season_id

    change_column_null :state_association_releases, :season_id, false

    remove_index :state_association_releases, name: 'index_sa_releases_on_grantor_and_recipient'

    add_index :state_association_releases,
              [:grantor_state_association_id, :recipient_game_operation_id, :season_id],
              unique: true,
              name: 'index_sa_releases_on_grantor_recipient_season'
    add_index :state_association_releases, :season_id, name: 'index_sa_releases_on_season_id'
  end

  def down
    remove_index :state_association_releases, name: 'index_sa_releases_on_grantor_recipient_season'
    remove_index :state_association_releases, name: 'index_sa_releases_on_season_id'

    add_index :state_association_releases,
              [:grantor_state_association_id, :recipient_game_operation_id],
              unique: true,
              name: 'index_sa_releases_on_grantor_and_recipient'

    remove_column :state_association_releases, :season_id
  end
end
