class CreatePublicSessionUsages < ActiveRecord::Migration[7.1]
  def change
    # Tages-Aggregat der Zugriffe anonymer Website-Besucher je Endpunkt, das
    # Gegenstück zu api_key_usages ohne Key. Eine Zeile pro Tag und Endpunkt.
    create_table :public_session_usages do |t|
      t.date :date, null: false
      t.string :endpoint, null: false, comment: 'controller#action, z. B. leagues#schedule'
      t.integer :count, null: false, default: 0

      t.timestamps
    end

    add_index :public_session_usages, %i[date endpoint], unique: true,
                                                         name: 'index_public_session_usages_unique'
  end
end
