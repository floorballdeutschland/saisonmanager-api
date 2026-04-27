class AddClubIdToReferees < ActiveRecord::Migration[7.0]
  def up
    add_column :referees, :club_id, :integer
    add_index :referees, :club_id

    remove_column :referees, :verein
    remove_column :referees, :landesverband
  end

  def down
    add_column :referees, :landesverband, :string
    add_column :referees, :verein, :string

    remove_index :referees, :club_id
    remove_column :referees, :club_id
  end
end
