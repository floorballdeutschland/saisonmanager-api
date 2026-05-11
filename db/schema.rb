# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2026_04_15_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "arenas", force: :cascade do |t|
    t.string "name"
    t.string "city"
    t.string "street"
    t.string "housenumber"
    t.string "postcode"
    t.string "address"
    t.string "schedule_item"
    t.boolean "active", default: false
    t.boolean "disabled", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "clubs", force: :cascade do |t|
    t.string "name"
    t.string "short_name"
    t.string "long_name"
    t.string "city"
    t.string "state"
    t.string "postcode"
    t.jsonb "game_operations_hash", default: []
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "state_association_id"
  end

  create_table "game_days", force: :cascade do |t|
    t.bigint "league_id"
    t.bigint "arena_id"
    t.bigint "club_id"
    t.integer "number"
    t.string "date"
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["arena_id"], name: "index_game_days_on_arena_id"
    t.index ["club_id"], name: "index_game_days_on_club_id"
    t.index ["league_id"], name: "index_game_days_on_league_id"
  end

  create_table "game_operations", force: :cascade do |t|
    t.string "name"
    t.string "short_name"
    t.string "path"
    t.string "logo_url"
    t.string "logo_quad_url"
    t.integer "state_association_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "games", force: :cascade do |t|
    t.bigint "game_day_id"
    t.bigint "home_team_id"
    t.bigint "guest_team_id"
    t.string "game_number"
    t.string "start_time"
    t.string "actual_start_time"
    t.string "game_status"
    t.string "ingame_status"
    t.integer "forfait", default: 0
    t.boolean "overtime", default: false
    t.boolean "overflow", default: false
    t.boolean "protest", default: false
    t.boolean "special_event", default: false
    t.boolean "playoff", default: false
    t.integer "audience"
    t.string "group_identifier"
    t.string "series_title"
    t.string "series_number"
    t.string "home_team_filling_rule"
    t.string "home_team_filling_parameter"
    t.string "guest_team_filling_rule"
    t.string "guest_team_filling_parameter"
    t.string "nominated_referee_string"
    t.integer "referee_ids", default: [], array: true
    t.string "referee1_string"
    t.string "referee2_string"
    t.boolean "referee1_signed", default: false
    t.boolean "referee2_signed", default: false
    t.string "time_keeper_string"
    t.boolean "time_keeper_signed", default: false
    t.string "record_keeper_string"
    t.boolean "record_keeper_signed", default: false
    t.boolean "home_captain_signed", default: false
    t.boolean "guest_captain_signed", default: false
    t.string "home_timeout_string"
    t.string "guest_timeout_string"
    t.string "live_stream_link"
    t.string "vod_link"
    t.string "notice_type"
    t.string "notice_string"
    t.text "record_comment"
    t.jsonb "events", default: []
    t.jsonb "players", default: {}
    t.jsonb "starting_players", default: {}
    t.jsonb "home_team_coaches", default: []
    t.jsonb "guest_team_coaches", default: []
    t.jsonb "awards", default: {}
    t.boolean "legacy", default: false
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "started", default: false
    t.boolean "ended", default: false
    t.boolean "game_ended", default: false
    t.datetime "record_created_at"
    t.datetime "record_updated_at"
    t.bigint "record_created_by"
    t.bigint "record_updated_by"
    t.integer "nominated_referee_ids", default: [], array: true
    t.datetime "match_record_closed_at"
    t.index ["game_day_id"], name: "index_games_on_game_day_id"
  end

  create_table "leagues", force: :cascade do |t|
    t.bigint "game_operation_id"
    t.string "name"
    t.string "short_name"
    t.string "season_id"
    t.string "league_class_id"
    t.string "league_category_id"
    t.string "league_system_id"
    t.string "league_type"
    t.boolean "female", default: false
    t.boolean "enable_scorer", default: false
    t.string "field_size"
    t.string "league_modus"
    t.boolean "has_preround", default: false
    t.bigint "league_id_preseason"
    t.bigint "league_id_preround"
    t.string "preround_point_modus"
    t.string "preround_scorer_modus"
    t.string "table_modus"
    t.integer "periods"
    t.integer "period_length"
    t.integer "overtime_length"
    t.string "order_key"
    t.date "deadline"
    t.date "before_deadline"
    t.boolean "legacy_league", default: false
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "direct_comparison", default: false, null: false
    t.index ["game_operation_id"], name: "index_leagues_on_game_operation_id"
  end

  create_table "license_fee_calculations", force: :cascade do |t|
    t.integer "user_id"
    t.datetime "started_at", precision: nil
    t.string "filename_json"
    t.string "filename_csv"
    t.string "filename_xls"
    t.integer "current_dataset"
    t.integer "season_id"
    t.float "percent"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "filename_other_json"
  end

  create_table "players", force: :cascade do |t|
    t.string "first_name"
    t.string "last_name"
    t.string "birthdate"
    t.string "gender"
    t.boolean "male"
    t.string "nation_id"
    t.string "security_id"
    t.jsonb "clubs", default: []
    t.jsonb "licenses", default: []
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "email"
  end

  create_table "referee_calculations", force: :cascade do |t|
    t.integer "user_id"
    t.datetime "started_at", precision: nil
    t.string "filename_json"
    t.string "filename_csv"
    t.string "filename_xls"
    t.integer "current_dataset"
    t.integer "season_id"
    t.float "percent"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "referees", force: :cascade do |t|
    t.integer "lizenznummer", null: false
    t.string "vorname", null: false
    t.string "nachname", null: false
    t.date "geburtsdatum"
    t.string "email"
    t.string "verein"
    t.string "landesverband"
    t.integer "game_operation_id"
    t.string "lizenzstufe"
    t.date "gueltigkeit"
    t.string "zusatzqualifikation"
    t.date "gueltigkeit_z"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_operation_id"], name: "index_referees_on_game_operation_id"
    t.index ["lizenznummer"], name: "index_referees_on_lizenznummer", unique: true
  end

  create_table "settings", force: :cascade do |t|
    t.jsonb "nations", default: {}
    t.jsonb "league_categories", default: {}
    t.jsonb "league_classes", default: {}
    t.jsonb "league_systems", default: {}
    t.jsonb "seasons", default: {}
    t.jsonb "systems", default: {}
    t.jsonb "user_groups", default: {}
    t.jsonb "penalties", default: {}
    t.jsonb "penalty_codes", default: {}
    t.jsonb "point_corrections", default: {}
    t.jsonb "liveticker", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "state_associations", force: :cascade do |t|
    t.string "name", null: false
    t.string "short_name"
    t.boolean "scan_required", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "teams", force: :cascade do |t|
    t.bigint "club_id"
    t.bigint "league_id"
    t.string "name"
    t.string "short_name"
    t.boolean "approved", default: false
    t.boolean "syndicate", default: false
    t.integer "syndicate_clubs", default: [], array: true
    t.integer "cup_leagues", default: [], array: true
    t.string "contact_person"
    t.string "contact_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["club_id"], name: "index_teams_on_club_id"
  end

  create_table "transfers", force: :cascade do |t|
    t.bigint "player_id"
    t.bigint "former_club_id"
    t.bigint "new_club_id"
    t.string "season_id"
    t.bigint "created_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.string "user_name", null: false
    t.string "email"
    t.string "first_name"
    t.string "last_name"
    t.string "password_digest"
    t.boolean "active", default: true
    t.bigint "club_id"
    t.integer "teams", default: [], array: true
    t.jsonb "permissions", default: []
    t.string "password_reset_token"
    t.datetime "last_login_at"
    t.string "hash_id"
    t.string "description"
    t.boolean "privacy_approved", default: false
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_name"], name: "index_users_on_user_name", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.string "event", null: false
    t.string "whodunnit"
    t.text "object"
    t.datetime "created_at"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "game_days", "arenas"
  add_foreign_key "game_days", "clubs"
  add_foreign_key "game_days", "leagues"
  add_foreign_key "games", "game_days"
  add_foreign_key "leagues", "game_operations"
  add_foreign_key "teams", "clubs"
end
