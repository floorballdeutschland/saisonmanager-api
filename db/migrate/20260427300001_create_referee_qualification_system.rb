class CreateRefereeQualificationSystem < ActiveRecord::Migration[7.0]
  def up
    create_table :referee_qualification_types do |t|
      t.string :name, null: false
      t.string :short_name
      t.boolean :active, default: true, null: false
      t.timestamps
    end
    add_index :referee_qualification_types, :name, unique: true

    create_table :referee_qualifications do |t|
      t.references :referee, null: false, foreign_key: true
      t.references :referee_qualification_type, null: false, foreign_key: true
      t.date :valid_until
      t.timestamps
    end

    # Seed default qualification types
    now = Time.current.utc.strftime('%Y-%m-%d %H:%M:%S')
    %w[A1 A2 A3 B].each do |name|
      execute(
        "INSERT INTO referee_qualification_types (name, short_name, active, created_at, updated_at) " \
        "VALUES ('#{name}', '#{name}', true, '#{now}', '#{now}')"
      )
    end

    # Migrate existing zusatzqualifikation free-text values that match a known type
    execute(<<~SQL)
      INSERT INTO referee_qualifications
        (referee_id, referee_qualification_type_id, valid_until, created_at, updated_at)
      SELECT r.id, qt.id, r.gueltigkeit_z, NOW(), NOW()
      FROM referees r
      JOIN referee_qualification_types qt ON qt.name = r.zusatzqualifikation
      WHERE r.zusatzqualifikation IS NOT NULL AND r.zusatzqualifikation != ''
    SQL

    remove_column :referees, :zusatzqualifikation
    remove_column :referees, :gueltigkeit_z
  end

  def down
    add_column :referees, :gueltigkeit_z, :date
    add_column :referees, :zusatzqualifikation, :string

    drop_table :referee_qualifications
    drop_table :referee_qualification_types
  end
end
