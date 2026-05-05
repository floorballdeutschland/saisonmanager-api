class CreateStateAssociationChecklistItems < ActiveRecord::Migration[7.0]
  def change
    create_table :state_association_checklist_items do |t|
      t.references :state_association, null: false, foreign_key: true
      t.text :question, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
  end
end
