# Tests

Saisonmanager nutzt Rails-Minitest (kein RSpec) plus **FactoryBot** für
Test-Daten. Die alten YAML-Fixtures (`test/fixtures/*.yml`) sind weitestgehend
leere `{}`-Stubs und werden Schritt für Schritt durch Factories ersetzt.

## Warum FactoryBot statt Fixtures

- **Lizenz-/Transfer-History sind JSONB-Arrays** mit pro-Test variabler Form;
  in YAML wären die Beispiele entweder nichtssagend (immer dasselbe) oder
  unleserlich (alle Edge-Cases gleichzeitig). Mit Factories beschreibt jeder
  Test seine genau benötigte History.
- **`Setting` ist Singleton**: in YAML einmal global, in Factories pro Test
  konfigurierbar (z. B. `current_season_id`, `current_min_team`).
- **User-Permissions** sind ein verschachteltes JSONB-Array — Traits
  (`:admin`, `:sbk_global`, `:vm`, …) lesen sich im Test deutlich besser als
  hartcodierte YAML.
- **Bestehende Fixtures bleiben** als leere `{}`-Stubs, damit die alten
  Test-Stubs nicht brechen; sie werden mitgeladen und sind harmlos.

## Factories

Liegen unter `test/factories/`. Aktueller Stand (Phase 1):

| Factory          | Notizen |
|------------------|---------|
| `:setting`       | Singleton — überschreibt vorhandene `Setting`-Zeile. Transients: `current_season_id`, `current_min_team`, `current_min_league`. |
| `:game_operation`| Standard-Verband. |
| `:club`          | Sequence-name; weitere Felder optional. |
| `:arena`         | Sequence-name + city. |
| `:league`        | Default-Saison `'18'`. Traits: `:current_season`, `:previous_season`, `:archived_season`. |
| `:team`          | `belongs_to :club, :league` via `association`. |
| `:player`        | Mit Transient `with_licenses: [{ team:, status:, season_id:, … }]` — generiert die JSONB-`licenses`-Array-Struktur inkl. History-Eintrag. |
| `:user`          | Traits: `:admin`, `:sbk_global`, `:sbk_scoped`, `:vm`, `:tm`. Permissions setzen `user_group_id` + optional `game_operation_id`/`club_id`. |

## Beispiel

```ruby
test 'Lizenz aus Vorsaison wird ausgefiltert' do
  create(:setting, current_season_id: '18', current_min_team: 1500)

  current_league  = create(:league, :current_season)
  previous_league = create(:league, :previous_season)

  current_team  = create(:team, league: current_league)
  previous_team = create(:team, league: previous_league)

  player = create(:player, with_licenses: [
    { team: current_team,  status: License::APPROVED },
    { team: previous_team, status: License::APPROVED }
  ])

  result = current_league.licenses
  player_ids = result.flat_map { |team| team[:players].map { |p| p[:id] } }
  assert_includes player_ids, player.id
end
```

## Konstanten

- `License::APPROVED = 1`, `REQUESTED = 2`, `DENIED = 3`, `DELETED = 4`,
  `DELETE_REQUESTED = 5`, `TRANSFER = 6`, `IGNORED = 7`, `WITHDRAWN = 8`
- User-Group-IDs: `1` Admin, `2` SBK, `3` RSK, `4` VM, `5` TM, `6` Schiri

## Caveats

- **`Player#save!`** schlägt fehl, wenn `email` gesetzt ist und nicht dem
  `URI::MailTo::EMAIL_REGEXP` entspricht. Wer Lizenz-History direkt
  manipuliert, sollte `save!(validate: false)` nutzen — die Factory tut das
  beim Aufbau ihrer JSONB-Strukturen nicht, weil sie auf neuen Records
  arbeitet, deren `email` `nil` ist.
- **`Setting.first`** ist Singleton — wenn ein Test `create(:setting, …)`
  ruft, löscht die Factory vorhandene `Setting`-Zeilen vorher (`Setting.delete_all`).
  Tests, die `Setting` nicht brauchen, sollen die Factory **nicht** aufrufen.
- **Mailer-Tests** über `ActionMailer::Base.deliveries`; im Test-Setup
  ggf. `ActionMailer::Base.deliveries.clear`.

## Phasen-Roadmap

- **Phase 1 (dieser PR)**: Factories + Lizenz/Saison-Modelltests + ein
  Rake-Task-Test als Proof
- **Phase 2 (#174)**: Controller-/Workflow-Tests (Lizenz, Transfer, Schiri),
  Frontend-CI
- **Phase 3 (#175)**: Invarianten-Tests, Data-Health-Checks, CI-Härtung
