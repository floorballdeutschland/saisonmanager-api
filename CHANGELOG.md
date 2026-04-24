# Changelog

Alle wesentlichen Änderungen am Saisonmanager werden hier dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), Versioning: [Semantic Versioning](https://semver.org/).

> **Patch** (1.0.**x**): Bugfixes · **Minor** (1.**x**.0): Neue Features · **Major** (**x**.0.0): Breaking Changes

---

## [Unreleased]

### Neu
- API-Key-Authentifizierung: Öffentliche Endpunkte erfordern jetzt einen `X-Api-Key`-Header oder eine gültige Cookie-Session; Keys werden im Admin-Bereich unter `/api/v2/admin/api_keys` verwaltet
- Spieler-Lineup: `youth`-Boolean (`true`, wenn Spieler unter 18) wird beim Hinzufügen zum Kader gespeichert – Basis für das Brillensymbol in der Aufstellung, ohne das Geburtsdatum öffentlich auszuliefern
- Spieltag-Bearbeitung: Als Ausrichter kann über einen versteckten Link ("Anderen Verein als Ausrichter wählen…") jeder Verein im System ausgewählt werden – relevant für Trophys und Endrunden, bei denen der Ausrichter nicht an der Liga teilnimmt (#256)
- Spielbericht-Eingabe: Im Spielverlauf (Ereignisliste) werden Trikot-Nummern der Spieler angezeigt, damit der Abgleich mit dem papiergebundenen Spielberichtsbogen einfacher fällt (#200)

### Verbessert
- Login: TM-Nutzer ohne Teams in der aktuellen Saison erhalten eine verständliche Fehlermeldung ("Keine Teams in der aktuellen Saison.") statt eines leeren Dashboards; Admin-, SBK- und VM-Rollen bleiben auch mit zusätzlicher TM-Rolle unberührt
- Spielplanverwaltung: Spieltage lassen sich per Klick auf den Header auf-/zuklappen; "Alle Spieltage auf-/zuklappen"-Button oben für längere Ligen (#281)
- Lizenzübersicht (Verband): Datum der Lizenzbeantragung und -erteilung pro Spieler wird mit angezeigt, um Zulässigkeitsprüfungen (z.B. für DM/SDM) zu erleichtern (#269)

## [1.2.5] - 2026-04-16

### Behoben
- Vereinsbearbeitung: `game_operations_hash = {}` (leerer Hash statt Array) führte zu einem `NoMethodError` beim Speichern eines Heimatverbands – `Club#game_operations_hash` normiert den Wert jetzt immer auf ein Array; Migration setzt alle Legacy-`{}`-Zeilen auf `[]`

## [1.2.4] - 2026-04-15

### Behoben
- Spielerbearbeitung: Spieler mit Lizenzen aus Saisons ohne `min_team_id` in der Setting-Konfiguration lösten einen `ArgumentError` aus – `Setting.current_min_team` und `current_min_league` geben jetzt `0` zurück, wenn das Feld fehlt
- Spielerbearbeitung: `User.find` und `Team.find` in `Player#full_hash` warfen `RecordNotFound`, wenn ein referenzierter User oder ein Team gelöscht wurde – auf `find_by` umgestellt
- `Team#full_hash`: Zugriff auf Liga- und Verbands-Felder ist jetzt nil-sicher (`league&.name` statt `league.name` etc.)

## [1.2.3] - 2026-04-15

### Behoben
- Spieler-Nationalität: Datenmigration behebt falsch angezeigte Nationalitäten durch Remapping der Legacy-IDs auf das neue System (27.642 deutsche Spieler zeigten „Dänemark" statt „Deutschland"; alle übrigen unbekannten Legacy-IDs werden als „Sonstige" klassifiziert)

## [1.2.2] - 2026-04-15

### Behoben
- Ligaverwaltung, Lizenzwesen/Verband und Vereins-Dropdowns: `go_ids.flatten` → `go_ids.flatten!` in `League`, `admin_league_permissions` und `admin_game_operations` – verschachtelte Arrays wurden nicht aufgelöst und `GameOperation.find` fand keine Einträge

## [1.2.1] - 2026-04-15

### Behoben
- Spielereignisse: VM/TM können keine Ereignisse mehr hinzufügen oder löschen, sobald der Spielbericht abgeschlossen ist (`match_record_closed` / `finalized`) – nur noch SBK und Admin (#246)
- Spielstatus: VM/TM können `game_status` nicht mehr ändern, wenn der Spielbericht bereits abgeschlossen ist – verhindert Umgehung der Ereignis-Sperre

## [1.2.0] - 2026-04-15

### Neu
- Spieler-Lineup: `gender` wird beim Hinzufügen zum Kader gespeichert und im Lineup-Eintrag mitgeliefert (Basis für „Kapitänin"-Anzeige, #154)
- Liga: `direct_comparison`-Flag – bei Punktgleichheit wird der direkte Vergleich (Punkte, Tordifferenz, Tore) vor der Gesamttordifferenz gewertet
- Globale Spielersuche: `GET /api/v2/admin/players/search?q=…` – sucht nach Name (Vor-, Nachname oder kombiniert), max. 20 Treffer (Admin/SBK)
- Spieler: optionales `email`-Feld; bei Lizenzerteilung durch SBK wird automatisch eine Bestätigungs-E-Mail versendet
- Schiedsrichter: bei Anlage (mit Lizenznummer) oder Änderung lizenzrelevanter Felder wird eine Info-E-Mail versandt
- Spielbericht: SBK und Admin können einen abgeschlossenen Spielbericht zurück in Nachbereitung setzen (`POST /api/v2/user/games/:id/reopen`)
- Logo-Upload für Vereine und Teams: `POST /api/v2/admin/clubs/:id/upload_logo` und `/teams/:id/upload_logo`
- Club-Logo wird automatisch an Teams vererbt (`logo_url_fallback`)
- Thumbnail-Variante (100×100) wird serverseitig erzeugt (`logo_small_url`)
- Schiedsrichter-Autocomplete: `GET /api/v2/referees/search?q=…` – sucht nach Name oder Lizenznummer, max. 10 Treffer (kein Login erforderlich)
- `nominated_referee_ids` (Integer-Array) an Games: SBK kann nominierende Schiedsrichter per ID hinterlegen

### Behoben
- `GameOperation#slug` Methode als einheitlicher Fallback (`short_name.parameterize`) wenn `path` nicht gesetzt ist; alle `game_operation_slug`-Felder in `Game`, `League`, `Team` und `TeamsController` nutzen jetzt `slug` – verhindert defekte „Weitere Wettbewerbe"-Links und inkonsistente Routen (#221)

### Verbessert
- Spieler: `nation_id` ist jetzt ein Pflichtfeld (Validierung auf > 0)
- Spiel-Detail: `hosting_club` (Ausrichterverein) wird jetzt im `full_hash` mitgeliefert (#279)
- ActiveStorage: Umstieg von Azure Blob Storage auf lokalen Disk-Service (`storage/`)
- Docker: persistentes Volume `rails_storage` für hochgeladene Logos
- Vereinsverwaltung: Heimatverband (`game_operation_id`) kann jetzt korrekt gespeichert werden
- Team-Statistikseite: Liga und Scorerliste werden jetzt korrekt über game_days ermittelt (team.league_id ist in den Produktionsdaten nicht gesetzt)
- Schiedsrichter: 5.362 Spiele mit Schiedsrichter-Strings nachträglich mit referee_ids, referee1_string und referee2_string versehen (via Namenserkennung aus nominated_referee_string)

## [1.1.1] - 2026-04-11

### Verbessert
- Domain-Migration: alle Verweise von `saisonmanager.de` auf `saisonmanager.org` umgestellt (Mailer, Game-URL, Rake-Tasks)
- `database.yml`: Verbindungsparameter werden jetzt aus ENV-Variablen gelesen (Docker-kompatibel)
- Seeds aktualisiert: Demo-Daten für Schiedsrichter, Vereine und Teams ergänzt
- `import_prod_data`: neuer Rake-Task zum Importieren öffentlicher Produktionsdaten

## [1.1.0] - 2026-04-10

### Neu
- Schiedsrichterverwaltung: CRUD-Endpunkte für Schiedsrichter-Stammdaten (RSK und Admin)
- Schiedsrichterverwaltung: Spielhistorie pro Schiedsrichter (`GET /admin/referees/:id/games`)
- Schiedsrichterverwaltung: Liste von Spielen mit unbekannten Schiedsrichtern (`GET /admin/referees/incorrect_assignments`)
- Öffentliche Lizenzabfrage (`GET /user/referees/:id`) jetzt DB-gestützt statt JSON-Datei
- 1441 Schiedsrichter-Stammdatensätze aus bestehender referees.json importiert

### Behoben
- Saisonwechsler: kein Absturz mehr beim Wechseln auf ältere Saisons ohne Liveticker-Konfiguration

## [1.0.0] - 2026-04-10

### Behoben
- Spielplan: Spiele werden jetzt numerisch nach Spielnummer sortiert (statt lexikalisch)
- Spielplan & Tabelle: kein Absturz mehr bei Teams ohne Vereinszuordnung
- Torschützenliste: kein Absturz mehr bei Spielern die nicht mehr in der Datenbank existieren

### Verbessert
- Spielplan-Endpunkt lädt Arena, Teams und Vereine jetzt in einer einzigen Query — deutlich schnellere Ladezeiten
