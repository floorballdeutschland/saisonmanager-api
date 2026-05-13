# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This is the Rails 7 API backend for the Floorball Saisonmanager. It lives in `~/saisonmanager-api` alongside `~/saisonmanager` (Angular frontend) and `~/saisonmanager-docker` (Docker Compose). See the frontend's CLAUDE.md for the full monorepo overview, deployment, and versioning workflow.

## Commands

```bash
# Lint
bundle exec rubocop

# Tests (Minitest, not RSpec despite guard-rspec in Gemfile)
bundle exec rails test
bundle exec rails test test/models/game_test.rb   # single file

# One-off scripts (run in Docker on production)
bundle exec rails runner scripts/update_referee_licenses.rb CSV_PATH=/path/to/members.csv
bundle exec rails runner scripts/import_referees.rb

# Run in Docker (dev)
cd ~/saisonmanager-docker
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails <command> RAILS_ENV=development

# Run in Docker (production)
cd ~/saisonmanager-docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml run --rm \
  -e RAILS_ENV=production rails-api bundle exec rails runner /app/tmp/script.rb
```

**Production scripts:** Copy script files to `/opt/saisonmanager/saisonmanager-api/tmp/` via `scp`, then run via `rails runner /app/tmp/script.rb` inside the container (the API repo is mounted at `/app`).

## Route structure

Two API versions coexist in `config/routes.rb`:

- **v1** (`api/v1/ticker/…`) – legacy ticker API, handled by `api_controller.rb`
- **v2** (`api/v2/…`) – main API, split into three access levels:
  - Public: `/api/v2/leagues/…`, `/api/v2/referees/search`, `/api/v2/state_associations`
  - User/VM/TM: `/api/v2/user/…` (lineup edits, license requests, game reports)
  - Admin/SBK: `/api/v2/admin/…` (CRUD for leagues, clubs, players, referees)
  - `namespace :admin` block handles `referees` and `state_associations` admin routes

## Auth & permissions

`ApplicationController` runs `authenticate_user` before every action via `cookies.signed[:user_id]`. Controllers that allow public access skip it explicitly.

Permission checks follow this pattern — always check `ph[:admin]` first, then role-specific:
```ruby
ph = current_user.permission_hash
allowed = ph[:admin].present? ||
          (ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id)))
```

`User#club_ids` returns `permission_hash[:vm]` — **empty for admin and SBK users**. Don't use it to check whether a user has access to clubs; use `Club.admin_user_clubs(user)` instead.

When building arrays of `go_ids` from `permission_hash`, always use `go_ids.flatten!` (mutating). `go_ids.flatten` (non-mutating) silently leaves nested arrays that break `GameOperation.find(go_ids)`.

## Key model patterns

**Setting** is a singleton config row (`Setting.current`, `Setting.first`). All league categories, seasons, penalties, etc. are stored as JSONB. Access seasons via `Setting.seasons` (class method returning array of `{id:, name:, current:}`) not `Setting.current.seasons` (returns raw JSONB hash keyed by string ID).

**Game** stores lineups and events as JSONB (`players`, `events`). `game_number` is text — sort numerically with `NULLIF(game_number, '')::integer NULLS LAST`. Key columns: `referee_ids` (integer array), `referee1_string` / `referee2_string` (format: `"<lizenznummer> Nachname, Vorname"`), `nominated_referee_ids` (integer array).

**Player** licenses and club memberships are JSONB arrays. `Player#players` (on Club) filters for currently active memberships — it's not a simple `has_many`. License status transitions live in a nested `history` array inside `Player#licenses`.

**Referee** games are found via `Referee#games` which queries `referee_ids` (integer array) OR `referee1_string LIKE '<lizenznummer> %'` OR `referee2_string LIKE '<lizenznummer> %'`. `nominated_referee_ids` is separate and not included in this search.

**Auditing:** `paper_trail` tracks model changes. `User.current_user` is set via `request_store` for whodunnit tracking (see `app/models/concerns/user_trackable.rb`).

## Versioning & Changelog

Version is defined in `config/initializers/version.rb` as `SAISONMANAGER_VERSION`.

Every PR requires a `## [Unreleased]` entry in `CHANGELOG.md` using sections `### Behoben`, `### Neu`, `### Verbessert`. On merge to `main`: bump version and move Unreleased → versioned block.
