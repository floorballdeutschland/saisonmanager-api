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

ActiveRecord::Schema[7.1].define(version: 2026_06_28_100000) do
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

  create_table "api_keys", force: :cascade do |t|
    t.string "name", null: false
    t.string "key_digest", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_used_at"
    t.integer "rate_limit", comment: "Max requests per minute; nil = unlimited"
    t.boolean "realtime", default: false, null: false
    t.index ["key_digest"], name: "index_api_keys_on_key_digest", unique: true
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
    t.string "contact_email"
    t.datetime "deactivated_at"
    t.bigint "deactivated_by"
  end

  create_table "daily_metrics", force: :cascade do |t|
    t.date "date", null: false
    t.string "metric_key", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["date", "metric_key"], name: "index_daily_metrics_on_date_and_metric_key", unique: true
  end

  create_table "email_logs", force: :cascade do |t|
    t.string "recipient", null: false
    t.string "cc"
    t.string "subject", null: false
    t.string "mailer_action"
    t.datetime "sent_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sent_at"], name: "index_email_logs_on_sent_at"
  end

  create_table "email_templates", force: :cascade do |t|
    t.string "mailer_class", null: false, comment: "z. B. RefereeMailer"
    t.string "action_name", null: false, comment: "z. B. published_assignment_notification"
    t.string "locale", default: "de", null: false
    t.string "subject"
    t.text "body", comment: "Optionaler HTML-Body mit {{platzhalter}}; leer = Code-Default (ERB-View)"
    t.string "from_address"
    t.string "reply_to_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mailer_class", "action_name", "locale"], name: "index_email_templates_on_key", unique: true
  end

  create_table "game_day_referee_confirmations", force: :cascade do |t|
    t.bigint "game_day_id", null: false
    t.bigint "referee_id", null: false
    t.datetime "confirmed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "properly_conducted", default: true, null: false
    t.jsonb "checklist_answers", default: [], null: false
    t.index ["game_day_id", "referee_id"], name: "index_game_day_referee_confirmations_unique", unique: true
    t.index ["game_day_id"], name: "index_game_day_referee_confirmations_on_game_day_id"
    t.index ["referee_id"], name: "index_game_day_referee_confirmations_on_referee_id"
  end

  create_table "game_day_secretary_links", force: :cascade do |t|
    t.bigint "game_day_id", null: false
    t.bigint "created_by_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_game_day_secretary_links_on_created_by_id"
    t.index ["game_day_id"], name: "index_game_day_secretary_links_on_game_day_id"
    t.index ["token_digest"], name: "index_game_day_secretary_links_on_token_digest", unique: true
  end

  create_table "game_day_team_confirmations", force: :cascade do |t|
    t.bigint "game_day_id", null: false
    t.bigint "team_id", null: false
    t.datetime "confirmed_at", null: false
    t.boolean "properly_conducted", default: true, null: false
    t.jsonb "checklist_answers", default: [], null: false
    t.bigint "confirmed_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_day_id", "team_id"], name: "index_game_day_team_confirmations_unique", unique: true
    t.index ["game_day_id"], name: "index_game_day_team_confirmations_on_game_day_id"
    t.index ["team_id"], name: "index_game_day_team_confirmations_on_team_id"
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
    t.datetime "host_notified_at"
    t.string "legacy_ref"
    t.index ["arena_id"], name: "index_game_days_on_arena_id"
    t.index ["club_id"], name: "index_game_days_on_club_id"
    t.index ["league_id", "number"], name: "index_game_days_on_league_id_and_number"
    t.index ["legacy_ref"], name: "index_game_days_on_legacy_ref", unique: true, where: "(legacy_ref IS NOT NULL)"
  end

  create_table "game_operations", force: :cascade do |t|
    t.string "name"
    t.string "short_name"
    t.string "path"
    t.string "logo_url"
    t.string "logo_quad_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "state_association_id"
    t.string "banner_link_url"
    t.index ["state_association_id"], name: "index_game_operations_on_state_association_id"
  end

  create_table "game_referee_reports", force: :cascade do |t|
    t.bigint "game_id", null: false
    t.bigint "uploaded_by_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_game_referee_reports_on_game_id", unique: true
    t.index ["uploaded_by_id"], name: "index_game_referee_reports_on_uploaded_by_id"
  end

  create_table "game_scans", force: :cascade do |t|
    t.bigint "game_id", null: false
    t.bigint "uploaded_by_id"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_game_scans_on_game_id", unique: true
    t.index ["uploaded_by_id"], name: "index_game_scans_on_uploaded_by_id"
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
    t.jsonb "checklist_answers", default: []
    t.string "checklist_veto_token_digest"
    t.datetime "checklist_veto_submitted_at"
    t.jsonb "checklist_veto_answers", default: []
    t.text "special_event_string"
    t.datetime "match_record_closed_at"
    t.string "legacy_ref"
    t.datetime "referee_feedback_notified_at"
    t.index ["checklist_veto_token_digest"], name: "index_games_on_checklist_veto_token_digest", unique: true, where: "(checklist_veto_token_digest IS NOT NULL)"
    t.index ["game_day_id"], name: "index_games_on_game_day_id"
    t.index ["guest_team_id"], name: "index_games_on_guest_team_id"
    t.index ["home_team_id"], name: "index_games_on_home_team_id"
    t.index ["legacy_ref"], name: "index_games_on_legacy_ref", unique: true, where: "(legacy_ref IS NOT NULL)"
    t.index ["referee_ids"], name: "index_games_on_referee_ids", using: :gin
  end

  create_table "league_qualifications", force: :cascade do |t|
    t.bigint "source_league_id", null: false
    t.bigint "target_league_id"
    t.integer "rank_from", null: false
    t.integer "rank_to", null: false
    t.string "qualification_type", null: false
    t.string "label"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_league_id"], name: "index_league_qualifications_on_source_league_id"
    t.index ["target_league_id"], name: "index_league_qualifications_on_target_league_id"
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
    t.boolean "before_deadline", default: false
    t.boolean "legacy_league", default: false
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "direct_comparison", default: false, null: false
    t.string "required_documents", default: [], array: true
    t.string "age_group"
    t.bigint "league_id_direct_encounters"
    t.string "banner_link_url"
    t.boolean "parental_consent_required", default: false, null: false
    t.integer "game_duration_minutes", comment: "Angenommene Spieldauer inkl. Puffer in Minuten für die Hallenbelegungs-/Konfliktprüfung; nil = globaler Default / perioden-basierter Fallback"
    t.boolean "referee_feedback_enabled", default: false, null: false
    t.string "legacy_ref"
    t.index ["game_operation_id"], name: "index_leagues_on_game_operation_id"
    t.index ["legacy_ref"], name: "index_leagues_on_legacy_ref", unique: true, where: "(legacy_ref IS NOT NULL)"
  end

  create_table "license_documents", force: :cascade do |t|
    t.bigint "player_id", null: false
    t.string "license_id", null: false
    t.string "document_type", null: false
    t.bigint "uploaded_by_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["player_id", "license_id", "document_type"], name: "idx_license_documents_unique", unique: true
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

  create_table "merge_logs", force: :cascade do |t|
    t.string "object_type", null: false
    t.bigint "master_id", null: false
    t.string "master_label"
    t.bigint "merged_id", null: false
    t.string "merged_label"
    t.bigint "performed_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_merge_logs_on_created_at"
    t.index ["object_type"], name: "index_merge_logs_on_object_type"
  end

  create_table "online_test_assignments", force: :cascade do |t|
    t.bigint "online_test_id", null: false
    t.bigint "referee_id", null: false
    t.bigint "assigned_by"
    t.datetime "assigned_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["online_test_id", "referee_id"], name: "index_online_test_assignments_on_online_test_id_and_referee_id", unique: true
    t.index ["online_test_id"], name: "index_online_test_assignments_on_online_test_id"
    t.index ["referee_id"], name: "index_online_test_assignments_on_referee_id"
  end

  create_table "online_test_attempts", force: :cascade do |t|
    t.bigint "online_test_id", null: false
    t.bigint "referee_id", null: false
    t.integer "attempt_number", null: false
    t.string "status", default: "in_progress", null: false
    t.jsonb "answers", default: [], null: false
    t.integer "error_points"
    t.datetime "started_at", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["online_test_id", "referee_id", "attempt_number"], name: "idx_online_test_attempts_unique", unique: true
    t.index ["online_test_id"], name: "index_online_test_attempts_on_online_test_id"
    t.index ["referee_id"], name: "index_online_test_attempts_on_referee_id"
  end

  create_table "online_test_questions", force: :cascade do |t|
    t.bigint "online_test_id", null: false
    t.integer "position", default: 0, null: false
    t.text "scenario", null: false
    t.jsonb "rows", default: [], null: false
    t.jsonb "solution", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["online_test_id", "position"], name: "index_online_test_questions_on_online_test_id_and_position"
    t.index ["online_test_id"], name: "index_online_test_questions_on_online_test_id"
  end

  create_table "online_tests", force: :cascade do |t|
    t.string "name", null: false
    t.string "lizenzstufe"
    t.integer "time_limit_minutes"
    t.integer "max_attempts", default: 2, null: false
    t.integer "pass_threshold_points"
    t.datetime "deadline"
    t.string "status", default: "draft", null: false
    t.bigint "created_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "player_change_requests", force: :cascade do |t|
    t.bigint "player_id", null: false
    t.integer "club_id", null: false
    t.integer "requested_by_user_id", null: false
    t.integer "reviewed_by_user_id"
    t.string "correction_type", null: false
    t.string "new_value"
    t.string "status", default: "pending", null: false
    t.text "rejection_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["club_id"], name: "index_player_change_requests_on_club_id"
    t.index ["player_id"], name: "index_player_change_requests_on_player_id"
    t.index ["status"], name: "index_player_change_requests_on_status"
  end

  create_table "player_suspensions", force: :cascade do |t|
    t.bigint "player_id", null: false
    t.bigint "team_id"
    t.date "valid_from", null: false
    t.date "valid_until", null: false
    t.text "reason"
    t.jsonb "affected_licenses", default: [], null: false
    t.bigint "created_by"
    t.datetime "lifted_at"
    t.bigint "lifted_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["player_id", "lifted_at"], name: "index_player_suspensions_on_player_id_and_lifted_at"
    t.index ["player_id"], name: "index_player_suspensions_on_player_id"
    t.index ["valid_until"], name: "index_player_suspensions_on_valid_until"
  end

  create_table "players", force: :cascade do |t|
    t.string "first_name"
    t.string "last_name"
    t.string "birthdate"
    t.string "gender"
    t.string "nation_id"
    t.string "security_id"
    t.jsonb "clubs", default: []
    t.jsonb "licenses", default: []
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "email"
    t.datetime "deactivated_at"
    t.integer "deactivated_by"
    t.integer "merged_into_id"
    t.string "deactivation_reason"
    t.index ["deactivated_at"], name: "index_players_on_deactivated_at"
  end

  create_table "proceeding_proposals", force: :cascade do |t|
    t.bigint "game_id", null: false
    t.bigint "state_association_id", null: false
    t.string "status", default: "pending", null: false, comment: "pending | rejected | opened"
    t.bigint "created_by_id", comment: "uploadender Schiri/User; ohne FK, User können gelöscht werden"
    t.bigint "decided_by_id"
    t.datetime "decided_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id"], name: "index_proceeding_proposals_on_game_id", unique: true
    t.index ["state_association_id"], name: "index_proceeding_proposals_on_state_association_id"
    t.index ["status"], name: "index_proceeding_proposals_on_status"
  end

  create_table "referee_assignments", force: :cascade do |t|
    t.bigint "game_id", null: false
    t.integer "referee1_id"
    t.integer "referee2_id"
    t.string "status", default: "tentative", null: false
    t.datetime "notified_tentative_at"
    t.datetime "published_at"
    t.bigint "created_by"
    t.bigint "updated_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "coach_id"
    t.integer "club_id"
    t.index ["club_id"], name: "index_referee_assignments_on_club_id"
    t.index ["coach_id"], name: "index_referee_assignments_on_coach_id"
    t.index ["game_id"], name: "index_referee_assignments_on_game_id", unique: true
  end

  create_table "referee_availabilities", force: :cascade do |t|
    t.bigint "referee_id", null: false
    t.date "date", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["referee_id", "date"], name: "index_referee_availabilities_on_referee_id_and_date", unique: true
    t.index ["referee_id"], name: "index_referee_availabilities_on_referee_id"
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

  create_table "referee_course_imports", force: :cascade do |t|
    t.bigint "uploaded_by_user_id", null: false
    t.string "filename"
    t.string "status", default: "in_review", null: false
    t.integer "total_rows", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["uploaded_by_user_id"], name: "index_referee_course_imports_on_uploaded_by_user_id"
  end

  create_table "referee_course_results", force: :cascade do |t|
    t.bigint "referee_course_import_id", null: false
    t.bigint "referee_id"
    t.bigint "state_association_id"
    t.integer "csv_lizenznummer"
    t.string "csv_vorname"
    t.string "csv_nachname"
    t.date "csv_geburtsdatum"
    t.string "csv_verein"
    t.string "csv_email"
    t.integer "master_lizenznummer_by_importer"
    t.string "master_vorname_by_importer"
    t.string "master_nachname_by_importer"
    t.date "master_geburtsdatum_by_importer"
    t.integer "master_club_id_by_importer"
    t.string "master_email_by_importer"
    t.integer "master_lizenznummer_final"
    t.string "master_vorname_final"
    t.string "master_nachname_final"
    t.date "master_geburtsdatum_final"
    t.integer "master_club_id_final"
    t.string "master_email_final"
    t.string "lizenzstufe"
    t.date "gueltigkeit"
    t.date "kursstichtag"
    t.jsonb "course_data", default: {}, null: false
    t.jsonb "import_warnings", default: [], null: false
    t.string "match_type", null: false
    t.integer "match_field_count", default: 0, null: false
    t.boolean "new_referee_created", default: false, null: false
    t.string "status", default: "pending_review", null: false
    t.bigint "reviewed_by_user_id"
    t.datetime "reviewed_at"
    t.datetime "applied_at"
    t.text "rejection_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["referee_course_import_id"], name: "index_referee_course_results_on_referee_course_import_id"
    t.index ["referee_id"], name: "index_referee_course_results_on_referee_id"
    t.index ["reviewed_by_user_id"], name: "index_referee_course_results_on_reviewed_by_user_id"
    t.index ["state_association_id", "status"], name: "index_referee_course_results_on_state_association_id_and_status"
    t.index ["state_association_id"], name: "index_referee_course_results_on_state_association_id"
    t.index ["status"], name: "index_referee_course_results_on_status"
  end

  create_table "referee_feedbacks", force: :cascade do |t|
    t.bigint "game_id", null: false
    t.bigint "team_id", null: false
    t.bigint "club_id"
    t.bigint "submitted_by_user_id"
    t.bigint "referee1_id"
    t.bigint "referee2_id"
    t.string "referee_names"
    t.integer "line_rating", null: false
    t.text "line_comment"
    t.integer "communication_rating", null: false
    t.text "communication_comment"
    t.text "general_comment"
    t.string "status", default: "visible", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "team_id"], name: "index_referee_feedbacks_on_game_id_and_team_id", unique: true
    t.index ["game_id"], name: "index_referee_feedbacks_on_game_id"
    t.index ["referee1_id"], name: "index_referee_feedbacks_on_referee1_id"
    t.index ["referee2_id"], name: "index_referee_feedbacks_on_referee2_id"
    t.index ["team_id"], name: "index_referee_feedbacks_on_team_id"
  end

  create_table "referee_license_levels", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "validity_years", default: 2, null: false
    t.index ["name"], name: "index_referee_license_levels_on_name", unique: true
  end

  create_table "referee_qualification_types", force: :cascade do |t|
    t.string "name", null: false
    t.string "short_name"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_referee_qualification_types_on_name", unique: true
  end

  create_table "referee_qualifications", force: :cascade do |t|
    t.bigint "referee_id", null: false
    t.bigint "referee_qualification_type_id", null: false
    t.date "valid_until"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["referee_id"], name: "index_referee_qualifications_on_referee_id"
    t.index ["referee_qualification_type_id"], name: "index_referee_qualifications_on_referee_qualification_type_id"
  end

  create_table "referees", force: :cascade do |t|
    t.integer "lizenznummer"
    t.string "vorname", null: false
    t.string "nachname", null: false
    t.date "geburtsdatum"
    t.string "email"
    t.integer "game_operation_id"
    t.string "lizenzstufe"
    t.date "gueltigkeit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "wallet_pass_issued_at"
    t.string "wallet_pass_url"
    t.string "strasse"
    t.string "hausnummer"
    t.string "plz"
    t.string "ort"
    t.integer "partner_lizenznummer"
    t.boolean "guest", default: false, null: false
    t.integer "club_id"
    t.integer "merged_into_id"
    t.string "telefonnummer"
    t.boolean "kurzfristig_mobil", default: false, null: false
    t.index ["club_id"], name: "index_referees_on_club_id"
    t.index ["game_operation_id"], name: "index_referees_on_game_operation_id"
    t.index ["lizenznummer"], name: "index_referees_on_lizenznummer", unique: true, where: "(lizenznummer IS NOT NULL)"
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

  create_table "state_association_checklist_items", force: :cascade do |t|
    t.bigint "state_association_id", null: false
    t.text "question", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["state_association_id"], name: "index_state_association_checklist_items_on_state_association_id"
  end

  create_table "state_association_releases", force: :cascade do |t|
    t.bigint "grantor_state_association_id", null: false
    t.bigint "recipient_game_operation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "season_id", null: false
    t.index ["grantor_state_association_id", "recipient_game_operation_id", "season_id"], name: "index_sa_releases_on_grantor_recipient_season", unique: true
    t.index ["grantor_state_association_id"], name: "index_sa_releases_on_grantor_id"
    t.index ["recipient_game_operation_id"], name: "index_sa_releases_on_recipient_go_id"
    t.index ["season_id"], name: "index_sa_releases_on_season_id"
  end

  create_table "state_associations", force: :cascade do |t|
    t.string "name", null: false
    t.string "short_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "vsk_email"
    t.string "sbk_email"
    t.integer "parent_id"
    t.boolean "express_license_enabled", default: false
    t.boolean "require_paper_game_report", default: false
    t.boolean "scan_required", default: false, null: false
    t.string "banner_link_url"
    t.boolean "referee_license_review_enabled", default: false, null: false
    t.boolean "manual_proceeding_creation", default: false, null: false, comment: "Wenn true: keine automatische VSK-Mail, stattdessen Verfahrensvorschlag an die SBK"
    t.boolean "referee_assignment_enabled", default: false, null: false
    t.index ["parent_id"], name: "index_state_associations_on_parent_id"
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
    t.string "legacy_ref"
    t.index ["club_id"], name: "index_teams_on_club_id"
    t.index ["legacy_ref"], name: "index_teams_on_legacy_ref", unique: true, where: "(legacy_ref IS NOT NULL)"
  end

  create_table "transfer_requests", force: :cascade do |t|
    t.bigint "player_id", null: false
    t.bigint "requesting_club_id", null: false
    t.bigint "former_club_id", null: false
    t.string "status", default: "pending_club", null: false
    t.integer "created_by", null: false
    t.integer "approved_by_club_user_id"
    t.datetime "club_approved_at"
    t.integer "approved_by_lv_user_id"
    t.datetime "lv_approved_at"
    t.integer "rejected_by"
    t.datetime "rejected_at"
    t.text "rejection_reason"
    t.integer "season_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "effective_date"
    t.string "request_type", default: "transfer", null: false
    t.integer "revoked_by"
    t.datetime "revoked_at"
    t.text "revocation_reason"
    t.string "player_confirmation_token"
    t.datetime "player_approved_at"
    t.datetime "player_rejected_at"
    t.boolean "direct", default: false, null: false
    t.index ["former_club_id"], name: "index_transfer_requests_on_former_club_id"
    t.index ["player_confirmation_token"], name: "index_transfer_requests_on_player_confirmation_token", unique: true
    t.index ["player_id"], name: "index_transfer_requests_on_player_id"
    t.index ["player_id"], name: "index_transfer_requests_on_player_id_active", unique: true, where: "((status)::text = ANY ((ARRAY['pending_club'::character varying, 'pending_player'::character varying, 'pending_lv'::character varying, 'scheduled'::character varying])::text[]))"
    t.index ["request_type"], name: "index_transfer_requests_on_request_type"
    t.index ["requesting_club_id"], name: "index_transfer_requests_on_requesting_club_id"
    t.index ["status"], name: "index_transfer_requests_on_status"
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
    t.bigint "referee_id"
    t.string "language", default: "de", null: false
    t.boolean "receive_info_mails", default: true, null: false
    t.index ["referee_id"], name: "index_users_on_referee_id"
    t.index ["referee_id"], name: "index_users_on_referee_id_unique", unique: true, where: "(referee_id IS NOT NULL)"
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
  add_foreign_key "game_day_referee_confirmations", "game_days"
  add_foreign_key "game_day_referee_confirmations", "referees"
  add_foreign_key "game_day_secretary_links", "game_days"
  add_foreign_key "game_day_secretary_links", "users", column: "created_by_id"
  add_foreign_key "game_day_team_confirmations", "game_days"
  add_foreign_key "game_day_team_confirmations", "teams"
  add_foreign_key "game_days", "arenas"
  add_foreign_key "game_days", "clubs"
  add_foreign_key "game_days", "leagues"
  add_foreign_key "game_referee_reports", "games"
  add_foreign_key "game_referee_reports", "users", column: "uploaded_by_id"
  add_foreign_key "game_scans", "games"
  add_foreign_key "game_scans", "users", column: "uploaded_by_id"
  add_foreign_key "games", "game_days"
  add_foreign_key "league_qualifications", "leagues", column: "source_league_id"
  add_foreign_key "league_qualifications", "leagues", column: "target_league_id"
  add_foreign_key "leagues", "game_operations"
  add_foreign_key "license_documents", "players", name: "license_documents_player_id_fkey"
  add_foreign_key "license_documents", "users", column: "uploaded_by_id", name: "license_documents_uploaded_by_id_fkey"
  add_foreign_key "online_test_assignments", "online_tests"
  add_foreign_key "online_test_assignments", "referees"
  add_foreign_key "online_test_attempts", "online_tests"
  add_foreign_key "online_test_attempts", "referees"
  add_foreign_key "online_test_questions", "online_tests"
  add_foreign_key "player_change_requests", "players"
  add_foreign_key "players", "players", column: "merged_into_id"
  add_foreign_key "referee_assignments", "games"
  add_foreign_key "referee_assignments", "referees", column: "referee1_id"
  add_foreign_key "referee_assignments", "referees", column: "referee2_id"
  add_foreign_key "referee_availabilities", "referees"
  add_foreign_key "referee_course_imports", "users", column: "uploaded_by_user_id"
  add_foreign_key "referee_course_results", "referee_course_imports"
  add_foreign_key "referee_course_results", "referees"
  add_foreign_key "referee_course_results", "state_associations"
  add_foreign_key "referee_course_results", "users", column: "reviewed_by_user_id"
  add_foreign_key "referee_feedbacks", "games"
  add_foreign_key "referee_qualifications", "referee_qualification_types"
  add_foreign_key "referee_qualifications", "referees"
  add_foreign_key "referees", "referees", column: "merged_into_id"
  add_foreign_key "state_association_checklist_items", "state_associations"
  add_foreign_key "state_association_releases", "game_operations", column: "recipient_game_operation_id"
  add_foreign_key "state_association_releases", "state_associations", column: "grantor_state_association_id"
  add_foreign_key "teams", "clubs"
  add_foreign_key "transfer_requests", "clubs", column: "former_club_id"
  add_foreign_key "transfer_requests", "clubs", column: "requesting_club_id"
  add_foreign_key "transfer_requests", "players"
  add_foreign_key "users", "referees"
end
