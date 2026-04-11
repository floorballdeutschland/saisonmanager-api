class CreateMainTables < ActiveRecord::Migration[7.0]
  def change
    create_table :settings do |t|
      t.jsonb :nations, default: {}
      t.jsonb :league_categories, default: {}
      t.jsonb :league_classes, default: {}
      t.jsonb :league_systems, default: {}
      t.jsonb :seasons, default: {}
      t.jsonb :systems, default: {}
      t.jsonb :user_groups, default: {}
      t.jsonb :penalties, default: {}
      t.jsonb :penalty_codes, default: {}
      t.jsonb :point_corrections, default: {}
      t.jsonb :liveticker, default: {}
      t.timestamps
    end

    create_table :game_operations do |t|
      t.string :name
      t.string :short_name
      t.string :path
      t.string :logo_url
      t.string :logo_quad_url
      t.timestamps
    end

    create_table :arenas do |t|
      t.string :name
      t.string :city
      t.string :street
      t.string :housenumber
      t.string :postcode
      t.string :address
      t.string :schedule_item
      t.boolean :active, default: false
      t.boolean :disabled, default: false
      t.timestamps
    end

    create_table :clubs do |t|
      t.string :name
      t.string :short_name
      t.string :long_name
      t.string :city
      t.string :state
      t.string :postcode
      t.jsonb :game_operations_hash, default: []
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    create_table :leagues do |t|
      t.references :game_operation, foreign_key: true
      t.string :name
      t.string :short_name
      t.string :season_id
      t.string :league_class_id
      t.string :league_category_id
      t.string :league_system_id
      t.string :league_type
      t.boolean :female, default: false
      t.boolean :enable_scorer, default: false
      t.string :field_size
      t.string :league_modus
      t.boolean :has_preround, default: false
      t.bigint :league_id_preseason
      t.bigint :league_id_preround
      t.string :preround_point_modus
      t.string :preround_scorer_modus
      t.string :table_modus
      t.integer :periods
      t.integer :period_length
      t.integer :overtime_length
      t.string :order_key
      t.date :deadline
      t.date :before_deadline
      t.boolean :legacy_league, default: false
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    create_table :teams do |t|
      t.references :club, foreign_key: true
      t.bigint :league_id
      t.string :name
      t.string :short_name
      t.boolean :approved, default: false
      t.boolean :syndicate, default: false
      t.integer :syndicate_clubs, array: true, default: []
      t.integer :cup_leagues, array: true, default: []
      t.string :contact_person
      t.string :contact_email
      t.timestamps
    end

    create_table :game_days do |t|
      t.references :league, foreign_key: true
      t.references :arena, foreign_key: true
      t.references :club, foreign_key: true
      t.integer :number
      t.string :date
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    create_table :games do |t|
      t.references :game_day, foreign_key: true
      t.bigint :home_team_id
      t.bigint :guest_team_id
      t.string :game_number
      t.string :start_time
      t.string :actual_start_time
      t.string :game_status
      t.string :ingame_status
      t.integer :forfait, default: 0
      t.boolean :overtime, default: false
      t.boolean :overflow, default: false
      t.boolean :protest, default: false
      t.boolean :special_event, default: false
      t.boolean :playoff, default: false
      t.integer :audience
      t.string :group_identifier
      t.string :series_title
      t.string :series_number
      t.string :home_team_filling_rule
      t.string :home_team_filling_parameter
      t.string :guest_team_filling_rule
      t.string :guest_team_filling_parameter
      t.string :nominated_referee_string
      t.integer :referee_ids, array: true, default: []
      t.string :referee1_string
      t.string :referee2_string
      t.boolean :referee1_signed, default: false
      t.boolean :referee2_signed, default: false
      t.string :time_keeper_string
      t.boolean :time_keeper_signed, default: false
      t.string :record_keeper_string
      t.boolean :record_keeper_signed, default: false
      t.boolean :home_captain_signed, default: false
      t.boolean :guest_captain_signed, default: false
      t.string :home_timeout_string
      t.string :guest_timeout_string
      t.string :live_stream_link
      t.string :vod_link
      t.string :notice_type
      t.string :notice_string
      t.text :record_comment
      t.jsonb :events, default: []
      t.jsonb :players, default: {}
      t.jsonb :starting_players, default: {}
      t.jsonb :home_team_coaches, default: []
      t.jsonb :guest_team_coaches, default: []
      t.jsonb :awards, default: {}
      t.boolean :legacy, default: false
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    create_table :players do |t|
      t.string :first_name
      t.string :last_name
      t.string :birthdate
      t.string :gender
      t.boolean :male
      t.string :nation_id
      t.string :security_id
      t.jsonb :clubs, default: []
      t.jsonb :licenses, default: []
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    create_table :users do |t|
      t.string :user_name, null: false
      t.string :email
      t.string :first_name
      t.string :last_name
      t.string :password_digest
      t.boolean :active, default: true
      t.bigint :club_id
      t.integer :teams, array: true, default: []
      t.jsonb :permissions, default: []
      t.string :password_reset_token
      t.datetime :last_login_at
      t.string :hash_id
      t.string :description
      t.boolean :privacy_approved, default: false
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
      t.index :user_name, unique: true
    end

    create_table :transfers do |t|
      t.bigint :player_id
      t.bigint :former_club_id
      t.bigint :new_club_id
      t.string :season_id
      t.bigint :created_by
      t.timestamps
    end
  end
end
