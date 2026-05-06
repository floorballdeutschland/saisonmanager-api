# Changelog

Alle wesentlichen Änderungen am Saisonmanager werden hier dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), Versioning: [Semantic Versioning](https://semver.org/).

> **Patch** (1.0.**x**): Bugfixes · **Minor** (1.**x**.0): Neue Features · **Major** (**x**.0.0): Breaking Changes

---

## [Unreleased]

---

## [1.6.0] - 2026-05-06

### Neu
- Schiedsrichter-Ansetzung: Veröffentlichungs-E-Mail enthält jetzt einen 72h-gültigen Link zu den Lizenzlisten beider beteiligter Teams; Hinweis auf mögliche Expresslizenzen ist enthalten
- Spielsekretariats-Link: VM/TM können per `POST /api/v2/user/game_days/:id/secretary_link` einen 72h-gültigen Link für einen Spieltag erzeugen; Ersteller wird gespeichert; Link erlaubt tokenbasierte Spielberichts-Eingabe und Einsicht der Lizenzlisten aller beteiligten Teams ohne separaten Login (#263, #283)
- Schiedsrichter-Berichtsformular: Incident-Report-E-Mail enthält Upload-Link; angesetzte Schiedsrichter können per `POST /api/v2/games/:id/referee_report` ein PDF hochladen, das automatisch per E-Mail (mit Anhang) an die VSK des Landesverbands des Ausrichtervereins weitergeleitet wird
- Landesverbände: VSK-E-Mail (`vsk_email`) und SBK-E-Mail (`sbk_email`) pro Landesverband pflegbar
- Spieltagscheckliste: Pro Landesverband können Ja/Nein-Fragen gepflegt werden (`admin/state_associations/:id/checklist_items`); ist mind. eine Frage definiert, muss die Checkliste vor dem Abschließen eines Spielberichts (`match_record_closed`) vollständig ausgefüllt werden; danach geht eine Bestätigungsmail an Ausrichterverein und beide Schiedsrichter; bei mind. einer Verneinung wird die SBK per BCC einbezogen und der abweichende Punkt aufgeführt
- Spielbericht-Scan: Ausrichtende Vereine erhalten nach Spieltagsabschluss eine E-Mail mit Links zum Hochladen des physischen Spielberichtsbogens (PDF/PNG/JPEG, max. 5 MB); Scans sind 12 Monate einsehbar und werden danach automatisch gelöscht
- Spielbericht-Scan: Feature pro Verband (GameOperation) konfigurierbar über `scan_required`-Flag
- Rake Task `game_scans:cleanup` zum automatisierten Entfernen abgelaufener Scan-Dateien

---

## [1.5.0] - 2026-04-30

### Neu
- Spielbericht: Ereignisse (Tore und Strafzeiten) können nachträglich bearbeitet werden (#165)
- Spielbericht: Spielstart wird gesperrt, bis für beide Teams eine Aufstellung hinterlegt ist; Backend validiert dies zusätzlich (#176)

---

## [1.4.0] - 2026-04-30

### Neu
- Liga-Lizenzliste: Weitere aktive Lizenzen (Beantragt/Genehmigt) eines Spielers in anderen Teams werden als Badge in der Übersicht angezeigt (#325)
- Lizenzantrag: Innerhalb von 24h nach Beantragung kann die Lizenz kostenfrei gelöscht werden (statt nur zurückgezogen); Ablaufzeitpunkt wird im API-Response mitgeliefert (#273)

### Verbessert
- Schiedsrichter-Vereinszuordnung: Einmalige Migration weist 3.057 Schiedsrichtern (93 %) anhand der Lizenznummer und eines Namensabgleichs mit dem CSV-Import die passende `club_id` zu; 250 Einträge ohne eindeutigen Treffer bleiben `null`

---

## [1.3.0] - 2026-04-27

### Neu
- Schiedsrichter-Vereinszuordnung: `verein`/`landesverband`-Freitextfelder durch `club_id` FK ersetzt; `landesverband` wird automatisch aus der Vereins-Landesverbandszugehörigkeit abgeleitet
- Schiedsrichter-Qualifikationssystem: Konfigurierbare Qualifikationstypen (`referee_qualification_types`) mit n:m-Verbindung (`referee_qualifications`) und individuellem `valid_until` je Eintrag; ersetzt die bisherigen `zusatzqualifikation`/`gueltigkeit_z`-Felder
- Schiedsrichter-Qualifikationstypen-Verwaltung: RSK/Admin verwalten Typen unter `/api/v2/admin/referee_qualification_types`
- Schiedsrichter-Vereinsansicht: Vereinsmanager können eigene Schiedsrichter unter `GET /api/v2/vm/referees` einsehen
- Schiedsrichter-Profil (Self-Service): Eingeloggte Schiedsrichter können über `GET/PUT /api/v2/referee/profile` Name, E-Mail, Heimadresse und Partner-Lizenznummer selbst bearbeiten
- Gastschiedsrichter: Neues `guest`-Flag auf `Referee`; Lizenznummer ist für Gäste optional, Anzeige als `G-{id}`; Lizenzbenachrichtigungs-E-Mails werden für Gäste nicht verschickt
- Adressfelder für Schiedsrichter: `strasse`, `hausnummer`, `plz`, `ort` und `partner_lizenznummer` als neue Felder auf `Referee`
- Vereins-Kontakt-E-Mail: Neues `contact_email`-Feld auf `Club` für Ansetzungs-Benachrichtigungen
- Schiedsrichter-Benutzerrolle (Gruppe 6): Schiri-User sehen nach Login nur „Mein Profil"; RSK-User erhalten zusätzlich Zugriff auf den Ansetzungs-Bereich
- Schiedsrichter-Sperrtermine: Schiedsrichter können über `GET/POST/DELETE /api/v2/referee/blocked_dates` zukünftige Samstage/Sonntage als gesperrt markieren; Löschen wird blockiert, wenn eine aktive Ansetzung existiert
- Schiedsrichter-Ansetzungen (RSK): Neuer Admin-Bereich unter `/api/v2/admin/referee_assignments` zum Anlegen, Aktualisieren, Benachrichtigen (vorläufig) und Veröffentlichen von Ansetzungen; Verfügbarkeitscheck per `/available` berücksichtigt Sperrtermine und bestehende Ansetzungen (Pokal-Ausnahme bei `league_category_id` 3/4)
- E-Mail-Benachrichtigungen für Ansetzungen: Vorläufig-E-Mail (nur Datum), Veröffentlichungs-E-Mail (Spiel, Halle, Partner, Ausrichter-Kontakt), Berichtsformular-Reminder (24h nach `match_record_closed` bei `special_event` oder Spielausschluss)
- Vereinsstatistik pro Schiedsrichter: Neuer Endpunkt `GET /api/v2/admin/referees/:id/club_stats?season_id=X` liefert Häufigkeit je Verein (heim + gast) über alle Spielhistorie des Schiedsrichters
- Öffentliche Lizenzcheck-Seite (`/lizenzcheck`): Lizenznummer eingeben → zeigt Gültigkeitsstatus, Lizenzstufe, Ablaufdatum und Verein; nutzt den bestehenden `GET /api/v2/user/referees/:lizenznummer`-Endpoint ohne Login (#328)
- Schiedsrichter-Wallet-Ausweis: Admin kann per `POST /api/v2/admin/referees/:id/wallet_pass` einen Passmeister-Pass ausstellen; `wallet_pass_issued_at` und `wallet_pass_url` werden auf dem Referee-Datensatz gespeichert (#328)
- API-Key-Authentifizierung: Öffentliche Endpunkte erfordern jetzt einen `X-Api-Key`-Header oder eine gültige Cookie-Session; Keys werden im Admin-Bereich unter `/api/v2/admin/api_keys` verwaltet
- Spieler-Lineup: `youth`-Boolean (`true`, wenn Spieler unter 18) wird beim Hinzufügen zum Kader gespeichert – Basis für das Brillensymbol in der Aufstellung, ohne das Geburtsdatum öffentlich auszuliefern
- Spieltag-Bearbeitung: Als Ausrichter kann über einen versteckten Link ("Anderen Verein als Ausrichter wählen…") jeder Verein im System ausgewählt werden – relevant für Trophys und Endrunden, bei denen der Ausrichter nicht an der Liga teilnimmt (#256)
- Spielbericht-Eingabe: Im Spielverlauf (Ereignisliste) werden Trikot-Nummern der Spieler angezeigt, damit der Abgleich mit dem papiergebundenen Spielberichtsbogen einfacher fällt (#200)

### Behoben
- Spieltag-Formular: Legacy-Hallen ohne strukturierte `city`-Adresse zeigten „KEINE ADRESSE HINTERLEGT" – `Arena#full_hash` liefert jetzt den berechneten `schedule_item`-Wert
- Spieltag-Formular: Ausrichter-Dropdown war leer, wenn eine Liga noch keine Teams hat – Frontend lädt automatisch die vollständige Vereinsliste
- Spieltag-Formular: Ausrichter-Dropdown für VM-Benutzer war leer – `admin_game_operations` leitet jetzt die Spielbetrieb-IDs korrekt über `club.main_game_operation_id` ab statt über eine nicht-existente `game_operation_id`-Spalte
- Vereinsbearbeitung: Heimatverband- und Bundesland-Dropdowns für Vereinsmanager-Rolle waren leer (gleiche Ursache wie oben)

### Verbessert
- Schiedsrichter-Bearbeitung: Lizenznummer-Feld im gesperrten Zustand jetzt gut lesbar (`disabled:bg-fb-gray-200 disabled:text-gray-700` statt fast-identischem Grau-auf-Grau) (#328)
- Login: TM-Nutzer ohne Teams in der aktuellen Saison erhalten eine verständliche Fehlermeldung ("Keine Teams in der aktuellen Saison.") statt eines leeren Dashboards; Admin-, SBK- und VM-Rollen bleiben auch mit zusätzlicher TM-Rolle unberührt
- Spielplanverwaltung: Spieltage lassen sich per Klick auf den Header auf-/zuklappen; "Alle Spieltage auf-/zuklappen"-Button oben für längere Ligen (#281)
- Lizenzübersicht (Verband): Datum der Lizenzbeantragung und -erteilung pro Spieler wird mit angezeigt, um Zulässigkeitsprüfungen (z.B. für DM/SDM) zu erleichtern (#269)
- Schiedsrichter-Autocomplete: Suche akzeptiert Multi-Wort-Queries ("Max Müller" findet jetzt Treffer auch bei separaten Vor-/Nachname-Spalten) und schlägt bereits ab dem ersten Zeichen Treffer vor. Im Spielbericht-Schritt 1 findet das Spielsekretariat Schiedsrichter damit auch per Namen schneller (#293)

### Geändert
- `team_license.approved_at` (in `League#licenses` und `Team#licenses`) wird jetzt als ISO-DateTime geliefert statt als vor-formatierter String `"dd.MM.yyyy HH:MM:SS"` – konsistent zu `requested_at` und per `date`-Pipe formatierbar. Kein aktueller Frontend-Konsument rendert das Feld direkt, daher keine sichtbare Regression. Externe Konsumenten müssen ggf. anpassen.

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
