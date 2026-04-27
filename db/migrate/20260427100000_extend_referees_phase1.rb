class ExtendRefereesPhase1 < ActiveRecord::Migration[7.0]
  def up
    add_column :referees, :strasse, :string
    add_column :referees, :hausnummer, :string
    add_column :referees, :plz, :string
    add_column :referees, :ort, :string
    add_column :referees, :partner_lizenznummer, :integer
    add_column :referees, :guest, :boolean, default: false, null: false

    change_column_null :referees, :lizenznummer, true

    remove_index :referees, name: 'index_referees_on_lizenznummer'
    add_index :referees, :lizenznummer, unique: true, where: 'lizenznummer IS NOT NULL',
              name: 'index_referees_on_lizenznummer'
  end

  def down
    remove_index :referees, name: 'index_referees_on_lizenznummer'
    add_index :referees, :lizenznummer, unique: true, name: 'index_referees_on_lizenznummer'

    change_column_null :referees, :lizenznummer, false

    remove_column :referees, :guest
    remove_column :referees, :partner_lizenznummer
    remove_column :referees, :ort
    remove_column :referees, :plz
    remove_column :referees, :hausnummer
    remove_column :referees, :strasse
  end
end
