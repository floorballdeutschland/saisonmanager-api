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

ActiveRecord::Schema[7.0].define(version: 2022_10_07_223502) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "hstore"
  enable_extension "plpgsql"
  enable_extension "uuid-ossp"

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

  create_table "arenas", id: :integer, default: -> { "nextval('tbl_arena_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "capacity"
    t.text "city"
    t.text "comment"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.boolean "disabled"
    t.text "housenumber"
    t.text "name"
    t.text "postcode"
    t.text "public_transport_note"
    t.text "street"
    t.text "travel_note"
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
  end

  create_table "clubs", id: :integer, default: -> { "nextval('tbl_club_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "city"
    t.jsonb "game_operations_hash"
    t.text "house_number"
    t.text "long_name"
    t.text "name"
    t.text "postcode"
    t.text "street"
    t.text "short_name"
    t.string "state", limit: 20, comment: "ISO 3166-2:DE"
    t.text "logo_url", default: "", null: false
    t.text "logo_small_url", default: "", null: false
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.integer "created_by"
    t.integer "updated_by"
  end

  create_table "game_days", id: :integer, default: -> { "nextval('tbl_game_day_id_seq'::regclass)" }, force: :cascade do |t|
    t.integer "arena_id"
    t.integer "club_id"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.text "date"
    t.integer "league_id"
    t.integer "number"
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
  end

  create_table "game_operations", id: :integer, default: -> { "nextval('tbl_game_operation_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "name"
    t.text "path"
    t.text "short_name"
    t.text "subdomains", array: true
    t.text "logo_url"
    t.text "logo_quad_url"
  end

  create_table "games", id: :integer, default: -> { "nextval('tbl_game_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.integer "old_id"
    t.integer "audience"
    t.integer "created_by"
    t.text "created_by_hash"
    t.datetime "created_at", precision: nil
    t.jsonb "events"
    t.integer "forfait", default: 0, null: false
    t.integer "game_day_id"
    t.integer "game_days"
    t.boolean "game_ended", default: false
    t.text "game_number"
    t.boolean "guest_captain_signed"
    t.jsonb "guest_team_coaches"
    t.integer "guest_team_id"
    t.text "guest_timeout_string"
    t.boolean "home_captain_signed"
    t.jsonb "home_team_coaches"
    t.integer "home_team_id"
    t.text "home_timeout_string"
    t.boolean "matchpenalty1"
    t.boolean "matchpenalty2"
    t.boolean "matchpenalty3"
    t.text "nominated_referee_string"
    t.boolean "overtime"
    t.jsonb "players"
    t.boolean "playoff"
    t.boolean "protest"
    t.text "record_comment"
    t.datetime "record_created_at", precision: nil
    t.integer "record_created_by"
    t.text "record_created_by_hash"
    t.boolean "record_keeper_signed"
    t.text "record_keeper_string"
    t.datetime "record_updated_at", precision: nil
    t.integer "record_updated_by"
    t.text "record_updated_by_hash"
    t.integer "referee_ids", array: true
    t.boolean "referee1_signed"
    t.text "referee1_string"
    t.boolean "referee2_signed"
    t.text "referee2_string"
    t.boolean "special_event"
    t.text "start_time"
    t.integer "status"
    t.boolean "time_keeper_signed"
    t.text "time_keeper_string"
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
    t.text "updated_by_hash"
    t.boolean "started", default: false, null: false
    t.boolean "ended", default: false, null: false
    t.text "live_stream_link"
    t.text "vod_link"
    t.text "actual_start_time"
    t.boolean "legacy", default: false, null: false
    t.text "notice_type"
    t.text "notice_string"
  end

  create_table "leagues", id: :integer, default: -> { "nextval('tbl_league_id_seq'::regclass)" }, force: :cascade do |t|
    t.boolean "before_deadline"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.text "deadline"
    t.boolean "female", default: false
    t.integer "game_operation_id"
    t.text "league_category_id", default: "1000"
    t.text "league_class_id"
    t.text "league_system_id", default: "4"
    t.text "name"
    t.text "order_key"
    t.text "season_id"
    t.text "short_name"
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
    t.boolean "enable_scorer", default: true, null: false
    t.string "field_size", limit: 10, default: "GF"
    t.text "league_modus"
    t.integer "league_id_preseason"
    t.integer "league_id_preround"
    t.boolean "has_preround", default: false, null: false
    t.text "preround_point_modus"
    t.text "preround_scorer_modus"
    t.text "table_modus", default: "classic", null: false
    t.boolean "legacy_league", default: false
    t.integer "periods", limit: 2, default: 3
    t.integer "period_length", limit: 2, default: 20
    t.integer "overtime_length", limit: 2, default: 10
  end

  create_table "license_fee_calculations", force: :cascade do |t|
    t.integer "user_id"
    t.datetime "started_at", precision: nil
    t.string "filename_json"
    t.string "filename_csv"
    t.string "filename_xls"
    t.integer "current_dataset"
    t.float "percent", default: 0.0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "season_id"
    t.string "filename_other_json"
  end

  create_table "players", id: :integer, default: -> { "nextval('tbl_player_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "birthdate"
    t.jsonb "clubs"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.text "first_name"
    t.text "last_name"
    t.jsonb "licenses"
    t.boolean "male"
    t.text "nation_id"
    t.jsonb "old_licenses_deleted_for_transfer"
    t.integer "updated_by"
    t.datetime "updated_at", precision: nil
    t.text "security_id", default: "uuid_generate_v4()", null: false
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

  create_table "settings", id: :integer, default: -> { "nextval('tbl_settings_id_seq'::regclass)" }, force: :cascade do |t|
    t.jsonb "league_categories"
    t.jsonb "league_classes"
    t.jsonb "league_systems"
    t.jsonb "license_states"
    t.jsonb "nations"
    t.jsonb "penalties"
    t.jsonb "penalty_codes"
    t.jsonb "point_corrections"
    t.jsonb "systems"
    t.jsonb "seasons"
    t.jsonb "user_groups"
    t.jsonb "liveticker", default: {}, null: false
  end

  create_table "teams", id: :integer, default: -> { "nextval('tbl_team_id_seq'::regclass)" }, force: :cascade do |t|
    t.boolean "approved", default: true
    t.integer "club_id"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.integer "cup_leagues", array: true
    t.integer "league_id"
    t.text "name"
    t.text "short_name"
    t.boolean "syndicate"
    t.integer "syndicate_clubs", array: true
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
    t.text "team_logo_path", default: "", null: false
    t.text "team_logo_small_path", default: "", null: false
    t.text "contact_person"
    t.text "contact_email"
  end

  create_table "transfers", id: false, force: :cascade do |t|
    t.integer "id", default: -> { "nextval('tbl_transfer_id_seq'::regclass)" }, null: false
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.integer "former_club_id"
    t.integer "game_operation_id"
    t.integer "new_club_id"
    t.integer "player_id"
    t.integer "season_id"
  end

  create_table "users", id: :integer, default: -> { "nextval('tbl_user_id_seq'::regclass)" }, force: :cascade do |t|
    t.boolean "active"
    t.datetime "created_at", precision: nil
    t.integer "created_by"
    t.integer "club_id"
    t.text "description"
    t.text "email"
    t.text "first_name"
    t.text "last_name"
    t.text "old_password"
    t.jsonb "permissions"
    t.boolean "privacy_approved"
    t.integer "teams", array: true
    t.datetime "updated_at", precision: nil
    t.integer "updated_by"
    t.text "user_name"
    t.text "security_id"
    t.text "password_digest"
    t.text "password_reset_token"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "arenas", "users", column: "created_by", name: "tbl_arena_fk"
  add_foreign_key "arenas", "users", column: "updated_by", name: "tbl_arena_fk1"
  add_foreign_key "game_days", "arenas", name: "tbl_game_day_fk2"
  add_foreign_key "game_days", "clubs", name: "tbl_game_day_fk"
  add_foreign_key "game_days", "leagues", name: "tbl_game_day_fk1"
  add_foreign_key "game_days", "users", column: "created_by", name: "tbl_game_day_fk3"
  add_foreign_key "game_days", "users", column: "updated_by", name: "tbl_game_day_fk4"
  add_foreign_key "games", "game_days", name: "tbl_game_fk2"
  add_foreign_key "games", "teams", column: "guest_team_id", name: "tbl_game_fk1"
  add_foreign_key "games", "teams", column: "home_team_id", name: "tbl_game_fk"
  add_foreign_key "games", "users", column: "created_by", name: "tbl_game_fk3"
  add_foreign_key "games", "users", column: "record_created_by", name: "tbl_game_fk5"
  add_foreign_key "games", "users", column: "record_updated_by", name: "tbl_game_fk6"
  add_foreign_key "games", "users", column: "updated_by", name: "tbl_game_fk4"
  add_foreign_key "leagues", "game_operations", name: "tbl_league_fk"
  add_foreign_key "leagues", "users", column: "created_by", name: "tbl_league_fk1"
  add_foreign_key "leagues", "users", column: "updated_by", name: "tbl_league_fk2"
  add_foreign_key "players", "users", column: "created_by", name: "tbl_player_fk", deferrable: true
  add_foreign_key "players", "users", column: "updated_by", name: "tbl_player_fk1", deferrable: true
  add_foreign_key "teams", "clubs", name: "tbl_team_fk1"
  add_foreign_key "teams", "leagues", name: "tbl_team_fk"
  add_foreign_key "teams", "users", column: "created_by", name: "tbl_team_fk2"
  add_foreign_key "teams", "users", column: "updated_by", name: "tbl_team_fk3"
  add_foreign_key "transfers", "clubs", column: "former_club_id", name: "tbl_transfer_fk1"
  add_foreign_key "transfers", "clubs", column: "new_club_id", name: "tbl_transfer_fk2"
  add_foreign_key "transfers", "game_operations", name: "tbl_transfer_fk"
  add_foreign_key "transfers", "players", name: "tbl_transfer_fk3"
  add_foreign_key "transfers", "users", column: "created_by", name: "tbl_transfer_fk4"
  add_foreign_key "users", "clubs", name: "tbl_user_fk"
  add_foreign_key "users", "users", column: "created_by", name: "tbl_user_fk1"
  add_foreign_key "users", "users", column: "updated_by", name: "tbl_user_fk2"
end
