class CreateApiKeyUsages < ActiveRecord::Migration[7.1]
  def change
    # Tages-Aggregat der API-Zugriffe je Key und Endpunkt. Aggregiert statt
    # protokolliert, damit die Tabelle nicht mit dem Verkehr wächst: Eine Zeile
    # pro Key, Tag und Endpunkt (controller#action) hält die Menge auch nach
    # Jahren im fünfstelligen Bereich.
    create_table :api_key_usages do |t|
      t.references :api_key, null: false, foreign_key: true
      t.date :date, null: false
      t.string :endpoint, null: false, comment: 'controller#action, z. B. leagues#schedule'
      t.integer :count, null: false, default: 0

      t.timestamps
    end

    add_index :api_key_usages, %i[api_key_id date endpoint], unique: true,
                                                             name: 'index_api_key_usages_unique'
    add_index :api_key_usages, :date
  end
end
