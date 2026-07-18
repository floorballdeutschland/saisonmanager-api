# Saisonmanager API

Rails 7 API backend for the Floorball Saisonmanager — a league management system for Floorball Deutschland covering schedules, player licensing, referee management, and club administration.

## Related Repositories

| Repo | Description |
|---|---|
| [saisonmanager](https://github.com/floorballdeutschland/saisonmanager) | Angular 22 frontend |
| [saisonmanager-api](https://github.com/floorballdeutschland/saisonmanager-api) | This repo – Rails 7 API |
| [saisonmanager-docker](https://github.com/floorballdeutschland/saisonmanager-docker) | Docker Compose setup for local development |

## Tech Stack

- **Ruby on Rails 7** (API mode)
- **PostgreSQL** with JSONB columns for flexible data (settings, player licenses, game events)
- **Docker** for local development (see saisonmanager-docker)
- **Minitest + FactoryBot** for tests
- **RuboCop** for linting

## Quick Start

The API is designed to run in Docker. See [saisonmanager-docker](https://github.com/floorballdeutschland/saisonmanager-docker) for the full setup.

```bash
cd ~/saisonmanager-docker

# Start the database
docker compose -f docker-compose.yml -f docker-compose.dev.yml up postgres -d

# Start the API (→ http://localhost:3001)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up rails-api -d

# First-time database setup
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails db:migrate RAILS_ENV=development
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails db:seed RAILS_ENV=development
```

> **Note:** Use `rails db:migrate`, not `rails db:schema:load` — the schema was bootstrapped from the initial migration file, not from a SQL dump, and `db:schema:load` fails in Docker due to a Unix socket issue.

### Demo Credentials

| Username | Password | Role |
|---|---|---|
| `admin` | `password123` | Admin – full access |
| `sbk_ost` | `password123` | SBK Ost – game operations |
| `sbk_west` | `password123` | SBK West |
| `vm_berlin` | `password123` | Vereinsmanager – Floorball Berlin |
| `tm_berlin1` | `password123` | Teammanager – Berlin Team 1 |

## Commands

```bash
# One-off Rails commands inside Docker
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails <command> RAILS_ENV=development

# Tests
bundle exec rails test
# single test file:
bundle exec rails test test/controllers/foo_controller_test.rb

# Lint
bundle exec rubocop

# Both also work inside Docker:
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rubocop
```

## Architecture

### Authentication

Cookie-based sessions via `cookies.signed[:user_id]`. `ApplicationController` calls `authenticate_user` before every action. The sessions controller sets the cookie on login.

Public endpoints require an `X-Api-Key` header (checked against the `ApiKey` table). Cookie sessions bypass the key check.

```ruby
# Public endpoint pattern
skip_before_action :authenticate_user, only: %i[show index]
before_action :authenticate_public_request, only: %i[show index]
```

### Permission System

Each `User` has a JSONB `permissions` array of objects `{ user_group_id, game_operation_id, club_id }`. The `permission_hash` method resolves this into role buckets:

| Key | Role | Scope |
|---|---|---|
| `:admin` | Administrator | Array of `game_operation_id`s; `[0]` = all |
| `:sbk` | Spielbetriebskommission | Array of `game_operation_id`s |
| `:rsk` | Referee commission | Array of `game_operation_id`s |
| `:vm` | Vereinsmanager | Array of `club_id`s |
| `:tm` | Teammanager | Array of `team_id`s (current season only) |

Permission check pattern:

```ruby
ph = current_user.permission_hash
go_id = resource.league.game_operation_id
allowed = ph[:admin].present? ||
          (ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id)))
```

> **`User#club_ids` returns `permission_hash[:vm]`** — it is empty for admin/SBK users even though they have broad access. Use `GET admin/clubs.json` to get accessible clubs for those roles.

### Data Model

```
GameOperation (Verband: FD, SBK Ost, SBK West…)
└── League
    ├── GameDay
    │   └── Game (JSONB: players, events, nominated_referee_ids)
    └── Team
         └── Player (JSONB: clubs, licenses)

Club
├── Player (membership via clubs JSONB)
└── StateAssociation (Landesverband)

Referee
User (JSONB: permissions; integer[]: teams)
Setting  (single-row global config)
ApiKey
```

### Key JSONB Columns

| Model | Column | Contents |
|---|---|---|
| `Setting` | (various) | `nations`, `league_categories`, `seasons`, `penalties`, etc. via `Setting.current` |
| `Game` | `players` | `{ "home": [...], "guest": [...] }` with trikot numbers |
| `Game` | `events` | Goal/penalty events used to compute score |
| `Player` | `clubs` | `[{ club_id, team_id, valid_until, ... }]` |
| `Player` | `licenses` | Array with nested `history` of status transitions |

> **`game_number` is stored as text.** Sort numerically with `NULLIF(game_number, '')::integer NULLS LAST`.

### Route Structure

```
GET /api/v2/version                    # public, no auth
POST /api/v2/sessions                  # login (no auth)
DELETE /api/v2/sessions                # logout

GET /api/v2/leagues/:id/schedule       # public (X-Api-Key or cookie)
GET /api/v2/leagues/:id/...            # public endpoints

/api/v2/admin/...                      # cookie session + role check
```

## Versioning

Semantic versioning defined in `config/initializers/version.rb`, exposed at `GET /api/v2/version`.

- **Patch** (1.0.x): bugfixes, no new functionality
- **Minor** (1.x.0): new user-facing features
- **Major** (x.0.0): breaking API changes

Changelog lives in `CHANGELOG.md` using `## [Unreleased]` → versioned entry workflow. When a version bump in `version.rb` lands on `main`, a GitHub Actions workflow automatically creates the matching `vX.Y.Z` tag and GitHub release.

## Deployment

CI (GitHub Actions) gates every PR with RuboCop + Minitest, but there is no CD — deploys are manual via:

```bash
ssh saisonmanager /opt/saisonmanager/deploy.sh
```

The script runs `git pull` on saisonmanager-docker, `git reset --hard origin/main` on this repo, then restarts nginx and rails-api containers.

## Contributing

- Branch from `main`: `git checkout -b fix/description` or `feat/description`
- Add an entry under `## [Unreleased]` in `CHANGELOG.md` for every PR
- Open a PR — no direct pushes to `main`; CI runs RuboCop and the Minitest suite

## Feedback & Contact

- Bug reports and feature requests from players, clubs, and officials: [saisonmanager-feedback](https://github.com/floorballdeutschland/saisonmanager-feedback) (German)
- Everything else: [it@floorball.de](mailto:it@floorball.de)
- Security vulnerabilities: please follow [SECURITY.md](SECURITY.md) instead of opening a public issue

## License

This project is licensed under the **GNU Affero General Public License v3.0** (AGPLv3) — see the [LICENSE](LICENSE) file for the full text.

© Floorball Deutschland. As an AGPLv3 work, you may use, study, share, and modify it under the license terms; networked deployments must make their corresponding source available to users.
