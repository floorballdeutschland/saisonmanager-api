class CreateStateAssociationReleases < ActiveRecord::Migration[7.0]
  def change
    create_table :state_association_releases do |t|
      t.references :grantor_state_association, null: false, foreign_key: { to_table: :state_associations }
      t.references :recipient_game_operation, null: false, foreign_key: { to_table: :game_operations }
      t.timestamps
    end

    add_index :state_association_releases,
              %i[grantor_state_association_id recipient_game_operation_id],
              unique: true,
              name: 'index_sa_releases_on_grantor_and_recipient'
  end
end
