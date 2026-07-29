class AddRefereeFeedbackContactToTeams < ActiveRecord::Migration[7.1]
  def change
    add_column :teams, :feedback_contact_email, :string
    add_column :teams, :feedback_contact_prefer_captain, :boolean, default: false, null: false
    add_column :teams, :feedback_contact_updated_at, :datetime
    add_column :teams, :feedback_contact_updated_by, :bigint
  end
end
