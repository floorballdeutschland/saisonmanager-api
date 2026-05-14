class CreateLicenseDocuments < ActiveRecord::Migration[7.1]
  def change
    create_table :license_documents do |t|
      t.references :player, null: false, foreign_key: true
      t.string :license_id, null: false
      t.string :document_type, null: false
      t.references :uploaded_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :license_documents, %i[player_id license_id document_type], unique: true,
              name: 'idx_license_documents_unique'
  end
end
