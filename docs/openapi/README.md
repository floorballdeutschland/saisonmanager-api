# OpenAPI-Spec

Die `openapi.yml` ist die **Single Source of Truth** für API-Verträge des Saisonmanagers.

## Aktueller Stand (PR A)

- Single-File-Spec (`openapi.yml`)
- 3 öffentliche Liga-Endpunkte dokumentiert: `/leagues/:id/schedule|table|scorer`
- Schema-Validierung in Tests via `committee-rails` aktiv
- Spec ist bewusst noch klein gehalten; `additionalProperties: true` lässt
  unbekannte Felder durch, sodass aktuelle Responses nicht brechen.

## Wozu

1. **Doku** – Swagger UI / Redoc rendert die Spec für Frontend- und Partner-Devs.
2. **Test-Validierung** – `committee-rails` validiert in Controller-Tests automatisch
   die Response gegen das Schema. Siehe `test/test_helper.rb` (`assert_schema_conform`).
3. **Frontend-Typsicherheit (geplant)** – `openapi-typescript` generiert
   TypeScript-Types im Frontend, sodass Schema-Drift beim Build auffällt.

## Lokal validieren

```bash
# Spec syntaktisch prüfen
npx @redocly/cli lint docs/openapi/openapi.yml

# Swagger UI lokal anzeigen
npx @redocly/cli preview-docs docs/openapi/openapi.yml
# → http://localhost:8080
```

## Spec erweitern

Reihenfolge der nächsten PRs (siehe Issue #150 und Phase 2 / #174):

1. **PR A (dieser PR)** – Foundation: Single-File-Spec + 3 öffentliche Endpunkte
2. **PR B** – Admin-Endpunkte: `admin/leagues`, `admin/clubs`, `admin/teams`,
   `admin/players`. Wenn die Spec dann zu unhandlich wird, in `paths/` und
   `components/schemas/` aufteilen und mit redocly bundlen.
3. **PR C** – Workflows: Lizenz (`license_request`, `handle_license_request`, …),
   Transfer (`admin/transfer_requests`), Schiri (`admin/referee_assignments`).
   Synchron zu Phase 2 der Test-Initiative (Issue #174).

## Konventionen

- **operationId**: camelCase, eindeutig (z. B. `getLeagueSchedule`).
- **additionalProperties: true** ist bei Skeleton-Schemas okay; pro Iteration
  enger schnüren, wenn die Felder vollständig dokumentiert sind.
- **Pflichtfelder**: nur Felder in `required`, die **in jeder Response** garantiert
  sind. Conditional Felder bleiben optional.
- **`nullable: true`** für Felder, die laut Implementierung explizit `nil` sein können.

## Anti-Patterns

- Keine ungeprüften Annahmen über Response-Felder; im Zweifel Implementierung lesen
  (Modell-Methode bzw. jbuilder-View) und ggf. den Test um eine Assertion erweitern.
- Keine Spec-Änderung ohne korrespondierenden Test, der das Schema treffen kann.
