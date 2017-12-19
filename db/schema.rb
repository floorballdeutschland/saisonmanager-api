# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20171218141634) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"
  enable_extension "hstore"

  create_table "arenas", id: :integer, default: -> { "nextval('tbl_arena_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.text "capacity"
    t.text "city"
    t.text "comment"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.boolean "disabled"
    t.text "housenumber"
    t.text "name"
    t.text "postcode"
    t.text "public_transport_note"
    t.text "street"
    t.text "travel_note"
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
  end

  create_table "clubs", id: :integer, default: -> { "nextval('tbl_club_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.text "city"
    t.jsonb "game_operations_hash"
    t.text "homepage_club"
    t.text "homepage_divison"
    t.text "homepage_division"
    t.text "house_number"
    t.text "long_name"
    t.text "name"
    t.text "postcode"
    t.text "street"
    t.text "short_name"
    t.string "state", limit: 20, comment: "ISO 3166-2:DE"
  end

  create_table "game_days", id: :integer, default: -> { "nextval('tbl_game_day_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.integer "old_id"
    t.integer "arena_id"
    t.integer "club_id"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.text "date"
    t.integer "league_id"
    t.integer "number"
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
  end

  create_table "game_operations", id: :integer, default: -> { "nextval('tbl_game_operation_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.text "name"
    t.text "path"
    t.text "short_name"
    t.text "subdomains", array: true
  end

  create_table "games", id: :integer, default: -> { "nextval('tbl_game_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.integer "old_id"
    t.integer "audience"
    t.integer "created_by"
    t.text "created_by_hash"
    t.datetime "created_at"
    t.jsonb "events"
    t.integer "forfait"
    t.integer "game_day_id"
    t.integer "game_days"
    t.boolean "game_ended"
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
    t.datetime "record_created_at"
    t.integer "record_created_by"
    t.text "record_created_by_hash"
    t.boolean "record_keeper_signed"
    t.text "record_keeper_string"
    t.datetime "record_updated_at"
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
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
  end

  create_table "leagues", id: :integer, default: -> { "nextval('tbl_league_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.boolean "before_deadline"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.text "deadline"
    t.boolean "female"
    t.integer "game_operation_id"
    t.text "league_category_id"
    t.text "league_class_id"
    t.text "league_system_id"
    t.text "name"
    t.text "order_key"
    t.text "season_id"
    t.text "short_name"
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
  end

  create_table "license_fee_calculations", force: :cascade do |t|
    t.integer "user_id"
    t.datetime "started_at"
    t.string "filename_json"
    t.string "filename_csv"
    t.string "filename_xls"
    t.integer "current_dataset"
    t.integer "percent"
    t.integer "season_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "players", id: :integer, default: -> { "nextval('tbl_player_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.integer "old_id"
    t.text "birthdate"
    t.text "city"
    t.jsonb "clubs"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.text "first_name"
    t.text "housenumber"
    t.text "last_name"
    t.jsonb "licenses"
    t.boolean "male"
    t.text "nation_id"
    t.jsonb "old_licenses_deleted_for_transfer"
    t.text "postcode"
    t.text "street"
    t.integer "updated_by"
    t.text "updated_by_hash"
    t.datetime "updated_at"
  end

  create_table "settings", id: :integer, default: -> { "nextval('tbl_settings_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
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
  end

  create_table "teams", id: :integer, default: -> { "nextval('tbl_team_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.boolean "approved"
    t.integer "club_id"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.integer "cup_leagues", array: true
    t.integer "league_id"
    t.text "name"
    t.text "short_name"
    t.boolean "syndicate"
    t.integer "syndicate_clubs", array: true
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
  end

  create_table "transfers", id: false, force: :cascade do |t|
    t.integer "id", default: -> { "nextval('tbl_transfer_id_seq'::regclass)" }, null: false
    t.text "hash_id"
    t.text "_rev"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.integer "former_club_id"
    t.integer "game_operation_id"
    t.integer "new_club_id"
    t.integer "player_id"
    t.integer "season_id"
  end

  create_table "users", id: :integer, default: -> { "nextval('tbl_user_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "hash_id"
    t.text "_rev"
    t.text "old_id"
    t.boolean "active"
    t.text "alternate_password"
    t.datetime "alternate_password_expiration"
    t.datetime "created_at"
    t.integer "created_by"
    t.text "created_by_hash"
    t.integer "club_id"
    t.text "description"
    t.text "email"
    t.text "first_name"
    t.text "last_name"
    t.text "password"
    t.jsonb "permissions"
    t.boolean "privacy_approved"
    t.integer "teams", array: true
    t.datetime "updated_at"
    t.integer "updated_by"
    t.text "updated_by_hash"
    t.text "user_name"
  end

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
  add_foreign_key "players", "users", column: "created_by", name: "tbl_player_fk"
  add_foreign_key "players", "users", column: "updated_by", name: "tbl_player_fk1"
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
