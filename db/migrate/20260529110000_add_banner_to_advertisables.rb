class AddBannerToAdvertisables < ActiveRecord::Migration[7.2]
  def change
    add_column :leagues, :banner_link_url, :string
    add_column :state_associations, :banner_link_url, :string
    add_column :game_operations, :banner_link_url, :string
  end
end
