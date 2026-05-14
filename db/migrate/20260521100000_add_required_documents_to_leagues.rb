class AddRequiredDocumentsToLeagues < ActiveRecord::Migration[7.0]
  def change
    add_column :leagues, :required_documents, :string, array: true, default: []
  end
end
