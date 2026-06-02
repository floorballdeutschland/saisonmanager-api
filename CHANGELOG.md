# Changelog

Alle wesentlichen Änderungen am Saisonmanager werden hier dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), Versioning: [Semantic Versioning](https://semver.org/).

> **Patch** (1.0.**x**): Bugfixes · **Minor** (1.**x**.0): Neue Features · **Major** (**x**.0.0): Breaking Changes

---

## [Unreleased]

### Behoben
- Team-Bearbeitung: Bei der Vereinsauswahl fehlten Vereine, die ein Landesverband für den Sportverbund der Liga freigegeben hat. `admin_get_go_clubs` berücksichtigt jetzt zusätzlich zu den eigenen Vereinen des Sportverbunds alle Vereine aus Landesverbänden, die per `StateAssociationRelease` für den jeweiligen Sportverbund und die Saison der Liga freigegeben sind

---

## [1.27.0] - 2026-06-02

### Neu
- Spielorte-Verwaltung: Suchfeld filtert die Arena-Liste nach Name und Stadt in Echtzeit (saisonmanager#530)
- Lizenzerteilung: Das neue Pflichtfeld „Gültig bis" wird beim Erteilen einer Lizenz gesetzt und standardmäßig auf den 31.07. des Saison-Endjahres vorbelegt. Abgelaufene Lizenzen erscheinen in der Globalübersicht rot und können automatisch per Rake-Task `licenses:expire` invalidiert werden (saisonmanager#536, #227)
- Teams-Import-Funktion für Playoffs/Meisterschaften geplant: LV-Admins können qualifizierte Teams aus einer Quell-Liga inkl. freigegebener Vereine anderer Landesverbände direkt in eine neue Liga importieren (saisonmanager#533, in Entwicklung)

### Verbessert
- Ligeneditor: Spielereinstellungs-Felder „Stichtag" / „vor Stichtag?" zu einer klar lesbaren Zeile zusammengefasst: „Spielberechtigt: geboren ab/bis [Datum]" (saisonmanager#535)
- Lizenzverwaltung: Nachträglich zur Liga hinzugefügte Pflichtdokument-Anforderungen (z.B. Anti-Doping) werden jetzt bei allen bestehenden Lizenzanträgen angezeigt; `documents_for` und der Lizenz-Endpunkt sind dynamisch erweiterbar (saisonmanager#534, #226)

### Behoben
- SBK-Spieler-View: Der „Reaktivieren"-Button fehlte im Admin/SBK-Bereich; VM-Nutzer konnten deaktivierte Spieler bereits reaktivieren, SBK-Nutzer nicht. Der API-Permission-Check erlaubte SBK bereits, der Button fehlte nur im Frontend (saisonmanager#531)
- Transferantrag: Fehlermeldungen der Spielersuche (z.B. „Spieler bereits in diesem Verein") wurden durch den `ErrorInterceptor` zu einem leeren String transformiert und als generisches „Fehler bei der Suche." angezeigt (saisonmanager#532)
- Datenfehler: 12 Vereine waren historisch dem falschen Landesverband zugeordnet (Bundesland ≠ LV-Zugehörigkeit). Betroffen: 4 BW-Vereine bei Bayern-LV, 5 Hessen-Vereine bei NRW-LV, 1 BW-Verein bei NRW-LV, 1 BW-Verein bei Hessen-LV, 1 Niedersachsen-Verein bei NRW-LV — direkt in Produktion korrigiert

---

## [1.26.0] - 2026-06-02

### Neu
- Neuer Endpoint `GET admin/state_associations/:state_association_id/releases/candidates`: liefert die für eine Lizenz-Freigabe möglichen **Empfänger-Sportverbünde** (alle Sportverbünde außer den eigenen des freigebenden Landesverbands). Bisher bot das Frontend im Ziel-Dropdown nur den eigenen Verbund an, was für eine Freigabe sinnlos ist. Der Endpoint ist über `StateAssociationWritable` auf Schreibberechtigte des jeweiligen LV beschränkt (#517)
- Vereinsmanager können jetzt im Frontend Benutzerkonten anlegen: Das Flag `menu_item_user_create` ist nun auch für VM gesetzt. Die serverseitige Logik (`Admin::UsersController#create`, auf Rolle TM/VM und den eigenen Verein gescoped) bestand bereits, war aber im UI nicht erreichbar (#518)

### Verbessert
- Benutzer-Übersicht (`GET admin/users`): Die Rollen-Einträge enthalten jetzt zusätzlich die aufgelösten Klartext-Namen `club_name` und `game_operation_name`, und pro Benutzer werden die zugeordneten Team-Namen (`team_names`) mitgeliefert. Damit kann das Frontend eine Zuordnungs-Spalte anzeigen (VM→Verein, TM→Team, SBK/RSK→Sportverbund). Die Namens-Lookups werden gebatcht (kein N+1) (#519)

### Behoben
- Platzierungs-/K.-o.-Spiele (z. B. DM-Halbfinals) wurden teils schon mit Teams befüllt, bevor die zugehörige Gruppenphase begonnen hatte. Ursache: Die Auffüll-Sperre in `Game.autofill_teams!` nutzte `match_record_not_closed` (SQL `NOT IN (...)`), das ungespielte Spiele mit `game_status = NULL` nicht erfasste – bei noch leerer Gruppentabelle wurden so Platzierungen aus der Anfangsreihenfolge übernommen. Es wird jetzt explizit geprüft, dass die Gruppe existiert und **alle** Gruppenspiele abgeschlossen sind, bevor `place_`-Regeln aufgelöst werden; zusätzlich Schutz gegen fehlende Tabellen-/Platz-Einträge (#515)
- Der SBK von Floorball Deutschland (global gescopter SBK, `ph[:sbk]` enthält `0`) hatte bisher **keinen** Zugang zur Verbandsverwaltung: Das Admin-Menü ist nur für echte Admins sichtbar, das regionale SBK-Menü blendet globale SBKs gezielt aus, und `scoped_state_associations` war für den globalen Scope leer. Ein globaler SBK bekommt jetzt den vollen Verbandsverwaltungs-View über **alle** Landesverbände (`menu_item_state_association_admin`) und darf deren Stammdaten/Einstellungen, Logo, Banner, Lizenz-Freigaben und Kontrollprozess-Fragen bearbeiten. Das Anlegen/Löschen ganzer Landesverbände sowie das Umhängen des übergeordneten Verbands (`parent_id`) bleiben weiterhin globalen Admins vorbehalten (neues Flag `state_association_manage_lifecycle`) (#215)
- Sicherheit: Mehrere mutierende SBK-/RSK-Aktionen prüften bisher nur, _ob_ ein Benutzer überhaupt SBK/RSK ist, aber nicht _für welchen Landesverband_. Anzeige/`index` waren jeweils korrekt gescoped, die mutierenden Aktionen jedoch nicht:
  - Lizenz-Genehmigung/-Ablehnung (`PlayersController#handle_license_request`): prüft jetzt die `game_operation_id` der zur Lizenz gehörenden Liga gegen den SBK-Scope (`0` = global) (#212)
  - Schiedsrichter-Ansetzungen (`Admin::RefereeAssignmentsController`): `create`/`update`/`notify`/`publish` prüfen jetzt, dass das (Ziel-)Spiel im RSK-Scope liegt; `index` filtert serverseitig analog zu `#games`. Ein RSK-LV kann damit keine Spiele fremder Landesverbände mehr ansetzen oder veröffentlichen (#213)
  - Spielerdaten-Korrekturen (`Admin::PlayerChangeRequestsController#approve`/`#reject`): prüfen jetzt, dass der Verein des Antrags im SBK-Scope liegt (analog `PlayerChangeRequest.for_go`) (#214)

---

## [1.25.1] - 2026-05-29

### Verbessert
- Landesverband-Detail (`GET admin/state_associations/:id`): Optionaler Query-Param `season_id` reicht bis zu `StateAssociation#full_hash` durch und zeigt die Lizenz-Freigaben (`releases`) der angefragten Saison statt nur der aktuellen. Ohne Param bleibt der Default die aktuelle Saison. Damit bleibt die Audit-Spur vergangener Saisons abrufbar, sobald die UI eine Saisonenauswahl erhält (#191)

### Behoben
- Performance: N+1-Queries in `meta_hash` durch den LV-Logo-Fallback behoben. `Club.admin_user_clubs`, `Club.admin_club_permissions` sowie die Liga-/Lizenzlisten in `league.rb` laden den Landesverband samt Logo-Attachment jetzt per Eager-Loading vor (`includes(state_association: { logo_attachment: :blob })`) statt pro GameOperation einzeln (#193)

---

## [1.25.0] - 2026-05-29

### Neu
- Landesverband-Selbstverwaltung für SBK: Der SBK eines Landesverbands kann jetzt seinen **eigenen** Landesverband vollständig selbst verwalten — Stammdaten und Einstellungen (`update`), Logo/Banner (`upload_logo`/`delete_logo`, `upload_banner`/`delete_banner`), Lizenz-Freigaben (`releases`) sowie Kontrollprozess-Fragen (`checklist_items`). Bisher war jeder Schreibzugriff auf globale Admins beschränkt und scheiterte für SBK mit `403`. Die Autorisierung ist in der Concern `StateAssociationWritable` gebündelt und strikt auf den gescopten LV begrenzt (`scoped_state_associations`); das Anlegen/Löschen ganzer Landesverbände sowie das Umhängen des übergeordneten Verbands (`parent_id`) bleiben globalen Admins vorbehalten
- "Lizenz erteilt"-E-Mail: Betreff und Textkörper enthalten jetzt zusätzlich die Liga (in Klammern) und die Saison (`Lizenz erteilt – Teamname (Liganame) - Saison XX/XX`); fehlt die Liga-Zuordnung, wird die Klammer weggelassen

### Verbessert
- Logo-Upload (Landesverband): Nur noch WebP erlaubt (statt PNG/JPEG); Fehlermeldung vom Backend wird im Frontend direkt angezeigt

### Behoben
- Landesverband-Verwaltung: RSK sah fälschlich den LV-Verwaltungs-Menüpunkt und konnte auf den Controller zugreifen, obwohl die Verwaltung dem SBK vorbehalten ist. `menu_item_state_association_sbk`, `authorize_sa_access!` und `scoped_state_associations` berücksichtigen jetzt nur noch `sbk` (nicht mehr `rsk`)

---

## [1.24.0] - 2026-05-29

### Neu
- Schiedsrichter-Kursergebnis-Import: CSV-Import für Kursergebnisse (Lizenznummer, Stammdaten, Kurs-Stufe/Datum/Punkte, Ausbilder) durch RSK FD und Admin. Pro Datensatz wird beim Review die Lizenzstufe gewählt; das Gültigkeitsdatum ist automatisch der 30.09. des Folgejahres vom letzten Kursdatum. Duplikatsprüfung über 6 Stammdatenfelder (Lizenznummer, Vor-/Nachname, Geburtsdatum, Verein, E-Mail) — leeres Feld auf einer Seite zählt symmetrisch als Match. Bei 6/6-Match wird ohne Freigabe übernommen; bei Teilmatch (≥3) bietet der Workflow Master-Wahl pro abweichendem Feld an. Korrekturen und Neuanlagen werden — sofern der Landesverband den Kontrollprozess aktiviert hat — dem RSK des Landesverbands zur Freigabe vorgelegt; er kann zustimmen oder die Stammdaten selbst korrigieren. Lizenzstufe und Gültigkeit sind für den LV-Reviewer read-only. Fehlende Lizenznummern werden bei der Anlage automatisch vergeben (höchste Nummer + 1)
- Landesverband-Einstellung: Neuer Schalter `referee_license_review_enabled` aktiviert/deaktiviert den Kontrollprozess für Schiedsrichterlizenzen pro Landesverband. Wird nur am Root-Landesverband konfiguriert; Kinder erben den Wert (`effective_referee_license_review_enabled`) analog zu `express_license_enabled` und `scan_required`
- Backend-Gate beim Aufstellen des Kaders (#187): Beim Hinzufügen eines Spielers zur Aufstellung (`POST /api/v2/user/games/:id/lineup/:side/add_player`) wird jetzt serverseitig geprüft, ob der Spieler eine erteilte (`APPROVED`) Lizenz für das aufstellende Team hat und ob die Lizenzklasse zur Liga des Spiels passt. Ist eine Bedingung nicht erfüllt, wird der Spieler weiterhin hinzugefügt (weicher Check), die Response enthält jedoch zusätzlich ein `warning`-Feld mit der Begründung, das das Frontend als Warnhinweis anzeigt. Verglichen wird ausschließlich `license.league_class_id` gegen `game.league.league_class_id`; Cup-Ligen mit abweichender Klasse (über `Team#cup_leagues`) werden in dieser Iteration bewusst nicht gesondert behandelt – dort kann der Check False-Positives erzeugen. **Breaking change** des Response-Shapes: Die Response ist jetzt `{ players: [...], warning: string | null }` statt eines reinen Arrays

### Behoben
- Schiedsrichter-Kursergebnis-Import (Robustheit, gleicher Feature-Block):
  - Submit verifiziert vor Anwendung Lizenzstufe, Gültigkeitsdatum und gültige Lizenzstufen-Namen (verhindert silent-Wipe der bestehenden Gültigkeit, wenn das Kursdatum in der CSV unparsebar war)
  - CSV-Parser sammelt pro Zeile `import_warnings` (unparsbare Datums-/Zahlenwerte) und liefert sie im API-Response für die Anzeige im Review
  - Header-Validierung der CSV — header-loses File führt nicht mehr zu silent Datenverlust
  - Encoding-Fehler (Windows-1252 statt UTF-8) liefern verständliche Fehlermeldung statt 500
  - Per-Zeilen-Fehler beim Submit werden mit Zeilennummer + Schiedsrichter-Identität ausgegeben (statt bare 500)
  - LV-Approve liefert konkrete Fehlermeldung wenn die Korrektur eine Validierung verletzt
  - Master-Stammdaten können vom LV-Reviewer explizit auf leer gesetzt werden (entferntes `.compact`)
  - Lizenz-Downgrades (neue Stufe ist Position-mäßig niedriger als bestehende) werden geloggt
  - Doppelapplikation eines bereits angewendeten Course-Result wird verweigert
  - Wenn kein Landesverband zu einem Datensatz ableitbar ist, wird Review erzwungen (safe-default)
  - Neuer `POST referee_course_results/:id/reject`-Endpoint für die LV-Kontrolle: weist einen Review-Datensatz mit Begründung zurück. Wenn der Submit-Schritt zuvor einen neuen Referee angelegt hat (`new_referee_created`) und dieser keine anderen Course-Results, Wallet-Pässe oder Spiele hat, wird er beim Reject mitgelöscht – verhindert Orphan-Referees nach Reviewer-Ablehnung
  - Upload validiert jetzt Größe (max. 5 MB) und Content-Type (Whitelist CSV-Varianten), bevor der Inhalt eingelesen wird – schützt vor versehentlichen Riesen-Uploads / Memory-DoS
  - Original-CSV wird via Active Storage als Audit-Trail am Import gespeichert und über `source_csv_url` ausgeliefert
  - Submit lockt den Import per `lock!` und prüft den Status danach erneut, damit zwei parallele Submits nicht beide den `Applier` durchlaufen
  - Match-Score-Logik (Import-Service vs. LV-Edit) auf `RefereeCourseResult.count_csv_to_referee_matches` konsolidiert – beide Pfade verwenden denselben symmetrischen Vergleich inkl. exaktem Vereinsabgleich
  - Lizenzstufen-Positionen werden im Applier pro Submit-Lauf gecacht (Thread-local), statt für jedes Result zwei `find_by`-Queries auszuführen
- TransferRequest-Workflow: `execute_transfer!`, `execute_release!` und `revoke_release!` lockten zwar den `TransferRequest`, aber nicht den `Player`. Damit war ein theoretischer Lost-Update auf `Player#clubs`/`Player#licenses` möglich, wenn parallel eine Freigabe zurückgezogen wurde. Innerhalb der Transaktion wird jetzt zuerst der Player und dann der TransferRequest gelockt (einheitliche Lock-Reihenfolge mit `players_controller.rb` zur Vermeidung von Deadlocks), und in `execute_release!` / `revoke_release!` wird der Status nach dem Lock erneut geprüft, um eine Lost-Update-Race zwischen Status-Check und Transaktion zu schließen. Zusätzlich invalidieren beide Methoden nun den `transfers`-Cache wie bereits `execute_transfer!` (#190)
- Analyse-Modul (#282): Tage und Monate ohne Aufrufe wurden in den Charts unter `/verwaltung/analyse` komplett ausgeblendet, statt mit Nullwerten zu erscheinen. Bei wenigen Datentagen führte das zu nur ein bis zwei extrem breiten Balken statt eines vollständigen 30-Tage- bzw. 12-Monate-Diagramms. `Admin::AnalyticsController#show` füllt fehlende Tage und Monate jetzt mit `count: 0`
- Analyse-Modul: Jeder erfolgreiche Aufruf der getrackten öffentlichen Endpunkte (`schedule`, `current_schedule`, `game_day_schedule`, `table`, `grouped_table`, `scorer`) wurde gezählt, sodass Reloads und Hintergrund-Polls eines einzelnen Besuchers die Kennzahl stark aufblähten. `LeaguesController#track_public_view` dedupliziert jetzt pro IP, Endpunkt und Pfad-Id über ein 30-Minuten-Fenster und nutzt `Rails.cache.write(..., unless_exist: true)`, damit parallele Requests nicht durch eine read+write-Race beide inkrementieren
- Schiedsrichter Wallet-Pass: Der Controller fängt jetzt zusätzlich zu `PassmeisterService::Error` auch jeden anderen `StandardError` ab, meldet die Exception an Sentry und liefert eine 422 zurück. `PassmeisterService::Error`-Fälle behalten die konkrete Original-Message (saubere Upstream-Diagnose), unerwartete Fehler (z. B. `NoMethodError`, Netzwerk-Timeouts) liefern stattdessen eine generische Fehlermeldung plus die Sentry-Event-ID als `sentry_id`-Feld, damit keine internen Implementierungs-Details ans Frontend leaken

---

## [1.23.0] - 2026-05-27

### Neu
- Zeitlich begrenzte Spielersperren (#508): Eine bestehende Team-Lizenz kann auf den Status „gesperrt" gesetzt werden (Lizenzaussetzung), oder es kann eine spielerweite Beantragungssperre mit Beginn- und Ablaufdatum eingerichtet werden. Eine Beantragungssperre setzt alle aktiven Lizenzen des Spielers automatisch aus und verhindert neue Lizenzanträge sowie das Erteilen wartender Anträge. Mit Ablauf des Datums werden betroffene Lizenzen automatisch auf ihren vorherigen Status reaktiviert (lazy beim nächsten Zugriff bzw. über die Rake-Task `licenses:expire_suspensions`). Verwaltung über `admin/players/:id/suspensions` (nur Admin/SBK)

### Behoben
- Release-Workflow: Die Changelog-Release-Notes wurden direkt in den Shell-Befehl interpoliert, wodurch ein gerades Anführungszeichen oder ein Backtick im Changelog-Text den `gh release create`-Aufruf zerschoss (z. B. `no matches found for entfällt` beim Release von 1.22.0). Die Notes werden jetzt sicher über eine Umgebungsvariable übergeben

---

## [1.22.1] - 2026-05-27

### Behoben
- Schiedsrichter-Berichts-E-Mails: Die Antwort-an-Adresse der Berichtsformular-Erinnerung (`incident_report_reminder`) und der VSK-Bericht-Mail (`referee_report_to_vsk`) zeigte auf die Ansetzungs-Adresse statt auf die zuständige SBK. Sie verweist nun auf die SBK-Adresse des jeweiligen Spielbetriebs (`sbk_email` des Landesverbands des game_operation), mit Fallback auf die Ansetzungs-Adresse, falls keine hinterlegt ist. Die Ansetzungs-Mails (`tentative_assignment_notification`, `published_assignment_notification`) bleiben unverändert bei der Ansetzungs-Adresse

---

## [1.22.0] - 2026-05-27

### Neu
- Schiedsrichter-Neuanlage: Beim Anlegen eines Schiedsrichters (kein Gast, mit Lizenznummer) wird jetzt automatisch der Wallet-Ausweis erzeugt und die Wallet-E-Mail an den Schiedsrichter verschickt – sofern eine E-Mail-Adresse hinterlegt ist. Die bisherige „Schiedsrichterausweis angelegt"-E-Mail entfällt dadurch. Schlägt die Pass-Erzeugung bei Passmeister fehl, wird der Fehler nur geloggt und die Anlage bleibt erfolgreich

### Verbessert
- Schiedsrichter-Wallet-Ausweis-E-Mail: Betreff jetzt „Dein Schiedsrichterausweis | <Name>", Antwort-an auf `rsk@floorball.de` umgestellt und der Hinweis am Ende verweist auf die Regel- und Schiedsrichterkommission von Floorball Deutschland. Zusätzlich erklärt die E-Mail nun die Gültigkeit des Ausweises (bis zum nächsten Regeljahr) und verlinkt den Lizenzchecker mit der persönlichen Lizenznummer zur Prüfung der laufenden Saisonlizenz
- Schiedsrichterlizenz-Update-E-Mail (bei Änderung von Lizenznummer, Gültigkeit oder Lizenzstufe): Wording von „Ausweis" auf „Lizenz" umgestellt (Betreff „Schiedsrichterlizenz aktualisiert – <Name>"), Antwort-an auf `rsk@floorball.de` geändert, Schlusshinweis auf die Regel- und Schiedsrichterkommission von Floorball Deutschland und ein Lizenzchecker-Hinweis mit persönlicher Lizenznummer ergänzt

---

## [1.21.1] - 2026-05-27

### Behoben
- Schiedsrichter-Wallet-Ausweis: Ausstellen schlug komplett fehl („Wallet-Pass konnte nicht erstellt werden"), weil der Barcode-Inhalt fälschlich als Top-Level-Felder `barcodeValue`/`barcodeAlternativeText` (Passcreator-Schema) übergeben wurde – die Passmeister-API lehnt diese mit `400 unknown or locked fields` ab. Korrekt sind die Dot-Notation-Felder `field.barcode.value` (zu codierender Lizenzcheck-Link) und `field.barcode.label` (Lizenznummer als Klartext). Damit wird der Pass wieder erstellt und der QR-Code gerendert

---

## [1.21.0] - 2026-05-27

### Neu
- Schiedsrichter-Wallet-Ausweis: Beim Ausstellen eines Wallet-Ausweises (`POST admin/referees/:id/wallet_pass`) erhält der Schiedsrichter jetzt eine E-Mail mit dem Wallet-Link – sofern eine E-Mail-Adresse hinterlegt ist. Vorher wurde der Pass nur erstellt, aber nicht an den Schiedsrichter kommuniziert
- Schiedsrichter-Wallet-Ausweis: Für Gast-Schiedsrichter (`guest`) wird kein Wallet-Ausweis mehr ausgestellt – der Endpoint lehnt die Anfrage ab

### Behoben
- Schiedsrichter-Wallet-Ausweis: Der Barcode (QR-Code) wurde nicht gerendert, weil der Lizenzcheck-Link fälschlich als `field.barcode.label` (ein nicht existierendes Custom-Field) statt als Barcode-Inhalt übergeben wurde. Der Link wird jetzt als `barcodeValue` (zu codierender Inhalt) gesendet, die Lizenznummer als `barcodeAlternativeText` (Klartext unter dem Code)

---

## [1.20.0] - 2026-05-27

### Behoben
- Schiedsrichter-Ausweis (Wallet): Passmeister-API-URL auf `www.passmeister.com/api/v1` aktualisiert (alte Subdomain `app.passmeister.com` nicht mehr auflösbar), Auth-Header auf `Bearer` umgestellt, `passId`-Feld korrekt benannt
- Schiedsrichter-Ausweis (Wallet): Request-Schema an die tatsächliche Passmeister-API angepasst. `passTypeId`/`passId` werden als Query-Parameter übergeben statt im Body; Feldwerte nutzen die geforderte Dot-Notation (`field.memberName.value`, `field.memberNumber.value`, `field.club.value.de`/`.en`, `field.barcode.label`); `expirationDate` → `expiresAt` mit vollständigem ISO-8601-Zeitstempel. Die Wallet-URL wird jetzt aus `pass.walletSafe.urls.default` der Response gelesen. Barcode-Label zeigt auf `https://sr.floorball.de/lizenzcheck/?q={Lizenznummer}`
- Startseite: GameOperation-Logo zeigt jetzt das Logo des verknüpften Landesverbands (hochladbar in der LV-Verwaltung) statt einer veralteten hartkodierten URL

### Verbessert
- Ansetzungsübersicht: PLZ und Ort der Spielstätte werden im API-Response der Spielliste (`GET admin/referee_assignments/games`) und der Ansetzungsliste (`GET admin/referee_assignments`) mitgeliefert (`arena_postcode`, `arena_city`)

### Neu
- Schiedsrichterverwaltung: Lizenzstufen sind jetzt konfigurierbar – neue Verwaltungsseite analog zu Zusatzqualifikationen; Lizenzstufen-Dropdown im Schiri-Formular wird dynamisch aus der konfigurierten Liste befüllt
- Admin: E-Mail-Log – Übersicht aller in den letzten 30 Tagen versendeten E-Mails (Empfänger, CC, Betreff, Mailer-Aktion, Zeitpunkt); Einträge älter als 30 Tage werden beim Laden automatisch gelöscht. Zusätzlich: Testmail an beliebige Adresse versendbar
- Schiedsrichterverwaltung: Lizenzstufen sind jetzt konfigurierbar – neue Seite „Lizenzstufen" analog zu Zusatzqualifikationen; Lizenzstufen-Dropdown im Schiri-Bearbeitungsformular wird aus der konfigurierten Liste befüllt statt aus einer festen Auswahl
- Schiedsrichter: Wird beim Schiedsrichter A eine Partner-Lizenznummer (bevorzugter Partner) gesetzt und der Partner B besitzt selbst noch keinen Partner-Eintrag, wird B automatisch mit A als Partner verknüpft – beide stehen sich danach gegenseitig drin. Bereits gesetzte Partner-Einträge bleiben unverändert. Existiert die angegebene Lizenznummer nicht, wird kein Fehler mehr erzeugt (zuvor: Validierungsfehler „nicht gefunden")
- Spielerfreigabe-Workflow ist jetzt nutzbar: `POST admin/transfer_requests` akzeptiert `request_type=release` und legt den Antrag entsprechend an (vorher wurde der Parameter im Backend ignoriert und jeder Antrag landete als regulärer Transfer). Beim finalen LV-Approval einer Freigabe wird der Spieler nicht umvereint, sondern erhält eine Zweit-Mitgliedschaft beim aufnehmenden Verein; die Lizenz für ein konkretes Team beantragt der Vereinsmanager separat nach Team-Zuordnung
- Spielerfreigabe: `execute_release!` versendet jetzt Abschluss-Mails (`transfer_completed`, bei Verbands-übergreifender Freigabe zusätzlich an aufnehmenden Landesverband). Vorher gab es bei erteilter Freigabe gar keine Benachrichtigung
- E-Mails zum Transfer/Freigabe-Workflow: Subject und Templates unterscheiden jetzt zwischen Transfer und Spielerfreigabe (Wording „Spielerfreigabe-Antrag" / „Spielerfreigabe erteilt" statt durchgängig „Transferantrag" / „Transfer vollzogen"). Insbesondere der `player_confirmation_request`-Mail-Body (Überschrift, „Von/Nach"-Labels, „Zustimmen/Ablehnen"-Buttons) ist jetzt vollständig branched
- Spielerfreigabe: Ein im `create` übergebenes `effective_date` wird bei `request_type=release` verworfen (statt akzeptiert und später stillschweigend ignoriert). Eine Freigabe wird beim LV-Approval immer sofort wirksam, hat kein Wunschdatum-Konzept
- Vereinsfreigaben (Landesverband → Sportverband): Freigaben sind jetzt an die Saison gekoppelt. Beim Anlegen wird `season_id` automatisch auf die aktuelle Saison gesetzt; in der Übersicht (`StateAssociation#full_hash`) erscheinen nur Freigaben der aktuellen Saison. Bestandsfreigaben werden per Migration auf die aktuelle Saison gesetzt. Bei Saisonwechsel erlischt eine Freigabe automatisch, es bleibt ein Audit-Eintrag in der Datenbank zurück
- Vereinsfreigaben: Aufnehmender Sportverband erhält bei freigegebenen Vereinen jetzt einen Read-only-Modus — keine `:update_club`/`:update_player`/`:create_player`-Permissions mehr. Die Auflistung in der Vereinsverwaltung (`Club.admin_user_clubs`) liefert weiterhin das bestehende Flag `released: true`, das jetzt eindeutig Read-only-Zugriff signalisiert (Frontend-Anbindung folgt in einem separaten PR)

### Verbessert
- API-Dokumentation: OpenAPI-3-Spec unter `docs/openapi/openapi.yml` als Single Source of Truth für API-Verträge eingeführt (Foundation: drei öffentliche Liga-Endpunkte `/leagues/:id/schedule|table|scorer`). Im Test-Modus validiert `committee-rails` Responses automatisch gegen das Schema; in Folge-PRs werden Admin- und Workflow-Endpunkte ergänzt (siehe Issue #150 und Phase 2 von Issue #174)
- Test-Infrastruktur: `committee-rails` als Test-Gem hinzugefügt, `assert_schema_conform` in `ActionDispatch::IntegrationTest` verfügbar; Smoke-Test für `LeaguesControllerTest` validiert die drei Foundation-Endpunkte gegen das Schema; `factory_bot_rails` als Test-Gem hinzugefügt, Factories für `Setting`, `GameOperation`, `Club`, `Arena`, `League` (mit Saison-Traits), `Team`, `Player`, `User` — YAML-Fixtures bleiben als Stubs erhalten, siehe `test/README.md`
- Aufgeräumt: `apipie-rails` aus Gemfile entfernt (war nur in einer Datei mit drei Annotationen genutzt und nicht aktiv gepflegt); ersetzt durch OpenAPI-Workflow
- Regressionsschutz Lizenz/Saison-Filter: `Setting.current_season_id` / `current_min_team` / `current_min_league` modelltestet (inkl. Fallback auf 0 aus PR #168), `Player#full_hash` / `Player#current_licenses` getestet auf Saison-, Status- und `min_team`-Filter, `League#licenses` getestet auf APPROVED-/REQUESTED-/DELETED-/DENIED-Filter, Vorsaison-Filter und `other_licenses`-Listing über mehrere Ligen
- Regressionsschutz Saisonwechsel-Routinen: Rake-Tasks `seasons:invalidate_stale_licenses` (Happy Path, Idempotenz, DRY_RUN, gelöschtes Team, unbekannte/fehlende `ADMIN_USER_ID`) und `seasons:backfill_min_ids` (gesetzt / unverändert / ohne Teams aus PR #171 / ohne Ligen / DRY_RUN) getestet
- Test-Suite wächst von 76 auf 103 Tests (+27 neu, +35 Assertions); Issue #173 (Phase 1 von #174/#175) damit abgeschlossen

### Behoben
- Schiedsrichter Wallet-Ausweis: `POST admin/referees/:id/wallet_pass` crashte mit `NoMethodError: undefined method 'verein' for Referee` — im Frontend erschien „Wallet-Pass konnte nicht erstellt werden.". `PassmeisterService#create_or_update_pass` greift jetzt über die `belongs_to :club`-Assoziation (`referee.club&.name`) auf den Vereinsnamen zu (vorher: das nicht existierende Attribut `referee.verein`)
- Spielsekretariats-Link: Aufruf des öffentlichen Endpoints (`GET /api/v2/public/secretary`) crashte mit `NoMethodError: undefined method 'name' for User`. Im Frontend erschien dadurch „Server-Fehler. Bitte versuche es später erneut." statt der Spieltagsansicht. `link.created_by&.name` durch `&.fullname` ersetzt — konsistent mit `GameDaySecretaryLinksController#create`
- Transfer-Vollzug: Beim finalen LV-Approval (`TransferRequest#execute_transfer!`) wurden **alle** aktiven Lizenzen des Spielers auf `License::TRANSFER` invalidiert — auch bestehende Lizenzen beim **aufnehmenden** Verein (z.B. aus einer zuvor erteilten Zweitlizenz). Lizenzen für Teams des aufnehmenden Vereins (`requesting_club_id`) werden jetzt explizit ausgeschlossen
- Transfer-Vollzug: `execute_transfer!` läuft jetzt mit einem Pessimistic Lock (`lock!`) auf dem TransferRequest und einer erneuten Status-Prüfung innerhalb der Transaktion. Vorher konnten zwei parallele `/execute`-Calls (z.B. Doppelklick im Admin-UI oder beim manuellen Vorziehen aus Status `scheduled`) doppelte `Transfer`-Records erzeugen und die Lizenz-History zweifach beschreiben
- Transferanträge: Unique-Index `index_transfer_requests_on_player_id_active` umfasst jetzt zusätzlich die Stati `pending_player` und `scheduled`. Vorher konnten während dieser beiden Phasen DB-seitig parallele Transferanträge für denselben Spieler angelegt werden (App-Check ist nicht atomar)
- Transfer-Vollzug: Öffentliche Transfer-Liste (`GET /api/v2/players/transfers`) zeigte vollzogene Transfers bis zu 30 Minuten verspätet, weil der `'transfers'`-Cache nicht invalidiert wurde. `execute_transfer!` ruft jetzt nach Abschluss der Transaktion `Rails.cache.delete('transfers')` auf
- Transferanträge: Der Bestätigungs-Token (`player_confirmation_token`) für den E-Mail-Link an den Spieler wird jetzt beim Übergang in jeden Endzustand entwertet (`withdrawn`, `rejected_by_club`, `rejected_by_lv`, `rejected_by_player`, `approved`, `revoked`). Vorher blieb der Link gültig und konnte auch nach Abschluss/Rücknahme noch aufgerufen werden (lief dann ins „error"-Redirect, exponierte aber den Token weiter)
- Vereinsfreigaben: Ein Sportverband mit aktiver Vereinsfreigabe eines anderen Landesverbands konnte über `Club#user_permissions` automatisch `:update_club` und `:update_player` für die freigegebenen Vereine und deren Spieler bekommen. Stammdaten von Fremd-LV-Vereinen ließen sich damit komplett ändern. Der Release-Pfad in `user_permissions` ist entfernt — Sichtbarkeit bleibt erhalten über die Auflistung in `Club.admin_user_clubs`, Schreibrechte gibt es nicht mehr
- Startseite: `GameOperation#meta_hash` lieferte bei Verbänden ohne hochgeladenes SA-Logo die veraltete `logo_url`-Textspalte als Fallback (hartcodierte externe URLs, z. B. `api.saisonmanager.de/verband/sbkost.png`). Der Fallback ist entfernt — `logo_url` ist jetzt `nil` wenn kein Logo hochgeladen wurde

---

## [1.19.0] - 2026-05-23

### Neu
- Lizenzen: Expresslizenz-Option erscheint im VM-Antragsdialog nur noch, wenn der zuständige Landesverband Expresslizenzen aktiviert hat **und** der erste Spieltag einer Liga des Teams höchstens drei Tage entfernt ist oder bereits stattgefunden hat
- Lizenzen: Beim Anlegen einer Expresslizenz wird zusätzlich eine separate E-Mail an die zuständige Spielbetriebskommission (`sbk_email` des Landesverbands) verschickt
- Saisonen: Rake-Task `seasons:invalidate_stale_licenses` markiert aktive Lizenzen (Status APPROVED/REQUESTED) als `DELETED` mit Reason „Saisonwechsel — Lizenz aus Vorsaison", wenn das zugehörige Team zu einer Liga außerhalb der aktuellen Saison gehört. Strukturelle Antwort auf bisher fehlende Saisonwechsel-Routine; nach Aktivierung einer neuen Saison aufrufen. `ADMIN_USER_ID=…` Pflicht (für History-Audit), `DRY_RUN=1` zeigt nur den Effekt an

### Behoben
- Saisonen: Beim Anlegen einer neuen Saison werden `min_league_id` und `min_team_id` automatisch gesetzt (`max(id) + 1`). Ohne diese Werte fiel `Setting.current_min_team` auf `0` zurück, dadurch wurden Vorsaison-Lizenzen weiterhin als „aktuell" gewertet (z. B. in der SBK-Lizenzansicht)
- Saisonen: Rake-Task `seasons:backfill_min_ids` setzt `min_league_id`/`min_team_id` für bestehende Saisons aus `min(id)` der zugeordneten Ligen/Teams; nötig, damit der Fix auch für die produktiv aktive Saison wirkt. `DRY_RUN=1` zeigt nur den Effekt an
- Vorrunden-Lizenzübernahme: Übernommene Lizenzen erhalten jetzt `season_id` (und `league_class_id`) der Zielliga. Ohne `season_id` ließen Saison-Filter (`lic_season.nil?` Bypass in `League#licenses`) sie als saisonunabhängig durchgehen, sodass übernommene Vorrunden-Lizenzen auch nach Saisonwechsel als „aktuell" galten
- Vorrunden-Lizenzübernahme: History-Eintrag enthält jetzt `created_by` (`current_user.id`); fehlte bisher und ließ `Player#current_license_status` über `User.find(nil)` ins `ActiveRecord::RecordNotFound` laufen
- Lizenzen: Rake-Task `licenses:backfill_season_ids` setzt `season_id` (und `league_class_id`) auf Bestandslizenzen ohne diese Felder anhand des verknüpften Teams/Liga. Nötig, damit bereits per Vorrunden-Übernahme erzeugte Lizenzen ebenfalls saisonkorrekt gefiltert werden. `DRY_RUN=1` zeigt nur den Effekt an
- Saisonen: Rake-Task `seasons:backfill_min_ids` setzt für archivierte Saisons (Ligen ohne Teams in der live-DB) keine Werte mehr; der bisherige `max(id)+1`-Fallback hat dort Müllwerte produziert, die im Falle einer Reaktivierung der Saison als falsche Filter-Schranke gewirkt hätten

### Verbessert
- Lizenzen: Backend ignoriert Express-Anträge außerhalb des 3-Tage-Fensters bzw. ohne LV-Freigabe und speichert sie als reguläre Lizenz (kein versehentlicher Mailversand)
- Lizenzverwaltung (Admin): API liefert `age_group` und `season_id` je Lizenzeintrag — Voraussetzung für die überarbeiteten Altersklassen- und Saison-Filter im Frontend

---

## [1.18.2] - 2026-05-23

### Behoben
- Analyse: `ActiveRecord::UnknownAttributeReference` durch `Arel.sql()` für `TO_CHAR`-Gruppierung behoben (#161)
- Spielbericht: 500er beim Eintragen der Trikotnummer im Kader-Editor; `player.birthdate` ist `varchar`, wurde fälschlich direkt mit `Date` verglichen — jetzt defensiv über `Date.parse` (#162)

---

## [1.18.1] - 2026-05-23

### Behoben
- Landesverband: Logo-Upload funktioniert (`upload_logo` / `delete_logo` Actions ergänzt)
- Landesverband: Banner (`banner_url`, `banner_link_url`) ist im öffentlichen Init-Endpoint enthalten und kann im Frontend angezeigt werden
- Landesverband: Banner-/Logo-Änderungen sind sofort sichtbar (Cache `settings/init` wird nach Upload/Löschen invalidiert)
- Schiedsrichter: Lizenznummer wird in der öffentlichen Spielansicht nicht mehr angezeigt
- Analyse: Ausstehende Migrationen (u. a. `daily_metrics`) nachgezogen — Endpoint liefert wieder Daten

### Sicherheit
- Landesverband-Logo akzeptiert kein SVG mehr (Stored-XSS-Risiko durch eingebettete Scripts)

---

## [1.18.0] - 2026-05-23

### Behoben
- CSRF-Token: Frontend sendet den Token jetzt im Header `X-CSRF-Token` (Rails-Standard) statt `X-XSRF-TOKEN`; behebt „CSRF token ungültig." beim Speichern (z. B. Liga anlegen)

### Neu
- Liga: Altersklasse (`age_group`) als eigenes Pflichtfeld; bestehende Ligen werden automatisch auf „Damen" oder „Herren" migriert
- Liga: 1. und 2. Floorball Bundesliga als Ligaklasse können nur noch von Admin- oder SBK-FD-Nutzern gesetzt werden
- Analyse: Tägliche Erfassung öffentlicher Seitenaufrufe (Spielplan, Tabelle, Torschützen); Admin-Bereich zeigt Übersicht der letzten 30 Tage und 12 Monate
- Transferliste (SBK): Zeigt nur erfolgreich abgeschlossene Transfers; CSV-Export der genehmigten Transfers

---

## [1.17.0] - 2026-05-23

### Behoben
- VM-Spielerliste: N+1-Query beim Lizenzstatus-Lookup durch JOIN ersetzt; team_id-Vergleich auf Integer vereinheitlicht
- SBK: Fehler beim Öffnen des Schiedsrichter-Bearbeiten-Formulars behoben (Qualifikationstypen konnten nicht geladen werden)
- Reaktivierung: Lizenzhistorie wird jetzt auch bei anderen Deaktivierungsgründen als "Vereinsaustritt" korrekt bereinigt
- Spielerzusammenführung: Deaktivierungsgrund wird als "Zusammenführung" gespeichert statt leer zu bleiben
- TM-Zugriff auf Spieler*innenliste auf aktuelle Saison beschränkt (historische TM-Rollen hatten keinen Zugriff mehr)
- Deaktivierungsgrund "Sonstiges": leere Begründung wird jetzt korrekt abgelehnt
- Security: CORS eingeschränkt auf saisonmanager.org; CSRF-Schutz für alle authentifizierten Requests; Login/Logout/Lost-Password vom CSRF-Check ausgenommen

### Neu
- Werbeflächen: Admins können Werbegrafiken (WebP, max. 500 KB, Verhältnis 6:1) auf Liga-, Landesverband- und Spielverbund-Ebene hinterlegen; Liga überschreibt Landesverband, Landesverband überschreibt Spielverbund; optionale Klick-URL pro Grafik
- Schiedsrichter: Spieltage können im Schiri-Portal als ordnungsgemäß durchgeführt bestätigt werden; werden sie nicht innerhalb von 48 Stunden bestätigt, gilt der Spieltag automatisch als bestätigt (beide Schiris einzeln)
- Admin: Qualifikationsregeln für Ligen – Platzierungsbereiche können mit Typen (Aufstieg, Playoffs, Playdowns, Abstieg, DM, Pokal) und optionaler Ziel-Liga hinterlegt werden; in der Ligatabelle farblich markiert
- TM: Zugriff auf Spieler*innenliste des Vereins (Meine Spieler*innen)
- VM/TM: E-Mail-Adresse von Spieler*innen kann direkt bearbeitet werden
- VM/TM: Spieler*innen können jetzt auch aus der Vereinsansicht heraus deaktiviert werden
- Spieler*in deaktivieren: Deaktivierungsgrund muss jetzt angegeben werden (Vereinsaustritt, Karriereende, Temporäre Pause, Sonstiges)
- Transfer: Spieler*innen erhalten eine E-Mail zur Bestätigung des Vereinswechsels; Transfer erst nach Zustimmung aktiv (pending_player-Schritt)

---

## [1.16.0] - 2026-05-20

### Neu
- Spieler*innen-Übersicht (VM): Spielernamen sind jetzt klickbar und führen direkt zur Detailseite, von der aus Korrekturanträge gestellt werden können

### Behoben
- Globale Lizenzliste: Lizenzen aus Vorsaisons wurden fälschlicherweise in die Erstlizenz-Bestimmung einbezogen und ließen neue Lizenzen als „Zweitlizenz" erscheinen

---

## [1.15.0] - 2026-05-20

### Neu
- Spielerdaten-Korrekturantragsworkflow: VM können Korrekturen für Stammdaten (Vorname, Nachname, Geburtsdatum, Nationalität, vertauschte Namen) beantragen; Admin/SBK genehmigen oder lehnen ab (#460/#138)
- Spielerprofil: Hinweistext am E-Mail-Feld erklärt die Verwendung der optionalen E-Mail-Adresse

---

## [1.14.0] - 2026-05-19

### Neu
- Duplikat-Zusammenführung für Spieler (Admin/SBK) und Schiedsrichter (Admin/RSK): zwei Datensätze können zu einem Master zusammengeführt werden; der sekundäre Datensatz wird soft-gelöscht (#422)
- Ansetzungen: Neuer Button „Speichern & veröffentlichen" speichert und veröffentlicht eine Ansetzung in einem Schritt; vorläufig gespeicherte Ansetzungen sind nur für Admin/SBK sichtbar (#429)
- Schiedsrichter-Neuanlage: Lizenznummer wird automatisch mit der nächsten freien Nummer vorbefüllt (höchste vorhandene + 1) (#446)
- Vereinsmanager können jetzt weitere VM- und TM-Nutzer für ihren Verein anlegen (#441)
- Landesverbände: Landes-SBK/RSK-Nutzer sehen jetzt ihren eigenen Landesverband unter `/verwaltung/landesverbaende`; Anlegen/Bearbeiten/Löschen bleibt Admin-Funktion
- GitHub-Release-Workflow: Bei jedem Merge auf `main` mit Versions-Bump wird automatisch ein GitHub Release mit den Changelog-Einträgen angelegt (#126)
- Tabelle: Direktbegegnungen aus einer Hinrunden-Liga können in die Rückrunden-Tabelle übernommen werden (`league_id_direct_encounters`); Spiele aus der Quell-Liga werden über Club-Zuordnung den Teams der aktuellen Liga zugeschrieben (#280)
- Rake-Task `cleanup:inactive_users`: Löscht VM/TM-Benutzerkonten ohne Login seit mehr als 3 Jahren; Admin/SBK/RSK/Schiedsrichter-Konten sind nicht betroffen. `DRY_RUN=1` zeigt nur den Effekt an (#442)
- Rake-Task `cleanup:old_transfer_requests`: Löscht abgeschlossene Transferanträge (approved/rejected/revoked/withdrawn) nach 3 Jahren Abschluss (status-spezifischer Zeitstempel, Fallback `created_at`). `DRY_RUN=1` zeigt nur den Effekt an (#444)
- Rake-Task `cleanup:all`: Führt beide Bereinigungsaufgaben in einem Schritt aus

### Verbessert
- Spielplan: Platzhalterteams in K.o.-Runden werden automatisch zugewiesen, sobald ein referenziertes Spiel abgeschlossen wird (#227)

### Behoben
- Duplikat-Zusammenführung Schiedsrichter: fehlende `set_referee`-Bindung für Merge-Action, falscher Spaltenname `qualification_type_id` (statt `referee_qualification_type_id`) sowie fehlende Transaktion und Berechtigungsprüfung für den Secondary-Datensatz behoben (#422)
- Duplikat-Zusammenführung Schiedsrichter: Lizenznummer der Secondary wird auf den Master übertragen, falls dieser keine besitzt; Game-Referenzen (`referee_ids`, `referee1_string`, `referee2_string`) werden in diesem Fall ebenfalls korrekt umgeschrieben (#422)
- Duplikat-Zusammenführung Spieler: Merge läuft jetzt in einer Transaktion, Berechtigung wird auch für den Secondary-Datensatz geprüft, bereits zusammengeführte Datensätze werden abgewiesen (#422)
- Vorrunden-Lizenzübernahme: `copy_preround_licenses` prüft jetzt vor der Berechtigungslogik, dass eine Cookie-Session existiert (verhinderte NoMethodError bei reinem API-Key-Aufruf); zudem läuft die Lizenzanlage in einer Transaktion, damit Teilausfälle keine inkonsistenten Daten hinterlassen
- Ansetzungen: RSK-Nutzer konnten `admin/settings/seasons` nicht aufrufen → 403-Fehler beim Laden der Ansetzungsseite behoben
- Schiedsrichterliste: RSK/SBK-Nutzer sehen nun alle ihnen zugeordneten Schiedsrichter, auch wenn die game_operation_id der Schiedsrichter direkt zugewiesen ist (#427)
- Schiedsrichterliste: Landes-SBK/RSK-Nutzer sehen nur noch Schiedsrichter ihres eigenen Landesverbands; fehlende `state_association_id` an GameOperations führte zuvor zu falschem globalem Scope (#427)
- RuboCop-Verstöße in `state_associations_controller` und `user.rb` behoben (Style/SymbolProc, Style/RedundantParentheses, Metrics/CyclomaticComplexity)

---

## [1.13.2] - 2026-05-15

### Verbessert
- Ansetzungen: Seite lädt standardmäßig nur Spiele ab dem heutigen Tag; "Von"-Filter ist vorausgefüllt und kann manuell geleert werden
- Navigation: Menüpunkte für Onlineprüfungen ausgeblendet

### Behoben
- Transferantrag-Detail und -Liste: Kontrast auf weißem Hintergrund korrigiert (dark-theme-Farben ersetzt, Hover-Farbe, Badge-Klassen, yellow-Status)

---

## [1.13.1] - 2026-05-15

### Neu
- Vereinsverwaltung: Vereine können von SBK/Admin deaktiviert und reaktiviert werden; deaktivierte Vereine erscheinen standardmäßig nicht in der Vereinsliste; neues Permission-Flag `club_deactivate` (#113)

### Verbessert
- Codequalität: überflüssige `Metrics/CyclomaticComplexity`-RuboCop-Direktive in `User#permissions_items` entfernt

### Behoben
- Lizenzdokumente: Whitelist für `document_type` entfernt – beliebige, vom Verband konfigurierte Dokumenttypen können jetzt hochgeladen werden (#112)
- Spielort löschen: Prüfung auf zugeordnete Spieltage ist nun saison-unabhängig; verhindert 500er bei Spielorten mit Spieltagen aus vergangenen Saisons (#90)
- Benutzerverwaltung: JSONB-Typmismatch beim Suchen von SBK/RSK-Nutzern behoben (Integer vs. String in `game_operation_id`); RSK-Nutzer erhalten Zugriff; eingeloggter Nutzer immer in der eigenen Liste sichtbar (#114)
- Schiedsrichter-Admin-Menü: VM-Nutzer sehen den Eintrag „Lizenzverwaltung" nicht mehr (führte zu leerer Liste); VM-spezifischer Schiedsrichter-View bleibt über `menu_item_referee_vm` erreichbar (#92)
- Lizenzliste: Abgelehnte Lizenzen erscheinen nicht mehr in der Verbandsansicht; `other_licenses` zeigt nur noch Lizenzen der aktuellen Saison (#111, #110)

---

## [1.13.0] - 2026-05-15

### Neu
- Spieler*innen-Verwaltung: Vereinsmanager (VM) können ihre Spieler*innen über `GET /admin/vm/players?club_id=<id>` abrufen (inkl. deaktivierter); Deaktivierung und Reaktivierung (`POST /admin/players/:id/deactivate|reactivate`) sind nun auch für VMs freigeschaltet; deaktivierte Spieler*innen erscheinen nicht in Lizenz-Dropdowns; neues Permission-Flag `menu_item_player_vm`
- Spielerstatistiken: `GET /players/:id/stats` liefert nun `deactivated_at` im `player`-Objekt
- Benutzerverwaltung: Verbund-Zuweisung (SBK/RSK) und Verein-Zuweisung (VM/TM) können nachträglich bearbeitet werden; TM-Team-Liste zeigt nur Vereins-eigene Teams
- Liga: Neues Feld `required_documents` (String-Array); konfiguriert welche Dokumente bei Lizenzanträgen erforderlich sind; wird in `user/team/:id/licenses.json` als `required_documents`-Feld ausgeliefert
- Transferanträge: Initiierender Verein (VM) kann offene Anträge im Status `pending_club` oder `pending_lv` zurückziehen (`PATCH /admin/transfer_requests/:id/withdraw`); neuer Status `withdrawn`
- Benutzerverwaltung: Vereinsmanager (VM) können Teammanager (TM) für ihren Verein anlegen und Teams zuweisen; Team-Zuweisung wird auf eigene Vereinsteams beschränkt
- Landesverbände: Logo-Upload und -Auslieferung via ActiveStorage (`has_one_attached :logo`); `logo_url` in allen API-Responses
- Rake-Task `state_associations:import_logos` lädt verfügbare Logos von floorball.de herunter
- Ansetzungen: `GET /api/v2/admin/referee_assignments/games` liefert Spiele für RSK-Ansetzungen (mit Ansetzungsstatus falls vorhanden)

### Behoben
- Transferanträge: `GET /admin/transfer_requests/:id` fehlte als Route – Detailseite lieferte immer 404
- Berechtigungen: SBK/RSK für nationales GO (kein Landesverband, z. B. FD) erhält globalen Zugriff auf Schiedsrichter- und Benutzerverwaltung
- Schiedsrichterverwaltung: globaler SBK (`[0]`) sieht jetzt alle Schiedsrichter (fehlender Early-Return analog zu RSK)
- Benutzerverwaltung: globaler SBK sieht jetzt alle Benutzer inkl. solcher ohne `club_id` (z. B. SBK-Nutzer selbst)
- Spielsekretariats-Link: URL enthielt Game-ID-Pfadsegment, das im Frontend nicht ausgewertet wird; bei Spieltagen ohne Spiele entstand dadurch eine ungültige URL (`/spielsekretariat/?token=…`)
- Ticker-API: URL-Feld zeigt jetzt auf `saisonmanager.org/spiel/:id` statt veralteter `fvd.saisonmanager.de`-Domain
- `Club`, `Team`, `StateAssociation`: Logo-Checks einheitlich auf `logo.attached?` umgestellt

---

## [1.12.0] - 2026-05-14

### Neu
- GitHub Actions CI: RuboCop und Tests laufen automatisch bei jedem PR gegen main (API und Frontend)
- Spielhistorie: Spielabschnitte ohne Ereignisse werden jetzt angezeigt; optionale Abschnitte (Verlängerung, Penalty-Schießen) erscheinen nur, wenn sie stattgefunden haben
- Benutzerverwaltung: SBK-Benutzer sehen jetzt auch sich selbst sowie andere SBK- und RSK-Benutzer des gleichen Verbunds (nicht nur VM/TM)
- Benutzerverwaltung: Rollenfilter im Frontend (Admin, SBK, RSK, VM, TM, Schiedsrichter)
- Navigation: Menüeintrag „Lizenzwesen (Verband)" heißt jetzt „Lizenzverwaltung"
- Spielorte: SBK und Admin können Spielorte löschen, sofern sie in der aktuellen Saison nicht verwendet werden
- Spielorte: Duplikate (gleicher Name und gleiche Adresse) werden per Datenmigration bereinigt; Spieltage werden auf den meistgenutzten Eintrag umgezogen
- Datenschutz: Bei Bundesliga-Teams enthält die Lizenz-Hash-Response `is_buli`; bei minderjährigen Spieler*innen werden `guardian_email` und `minor_consent_at` im Lizenzantrag gespeichert (§ 4.12 SPO / Art. 13 DSGVO)

### Behoben
- Spielorte: `disabled`-Feld entfernt; die Deaktivieren-Funktion wurde nie genutzt und wird nicht länger unterstützt

---

## [1.11.0] - 2026-05-13

### Neu
- Onlineprüfungen für Schiedsrichter: RSK kann Tests anlegen, Fragen (Szenario + Matrix) erfassen, SR manuell zuweisen und veröffentlichen; SR absolvieren Tests mit Countdown-Timer (max. 2 Versuche); Ergebnisse nach Deadline automatisch sichtbar

---

## [1.10.3] - 2026-05-13

### Entfernt
- LV-Zuordnung je Verband (Dropdown auf Ligaverwaltungs-Seite und `PATCH admin/game_operations/:id`): `scan_required` wird künftig direkt in den Landesverband-Einstellungen konfiguriert

---

## [1.10.2] - 2026-05-13

### Behoben
- Verband-Zuordnung: 500er wenn Session abgelaufen war (`game_operations#admin_update` fehlender `current_user`-Check)
- Saison-Wechsel: `current_season_id` wurde durch JSONB-In-Place-Mutation nicht gespeichert

### Neu
- Benutzerverwaltung: SBK kann VM- und TM-Nutzer anlegen; neuer Nutzer erhält Passwort-Reset-E-Mail (#255)
- Benutzerverwaltung: Inaktive Nutzer (kein Login seit > 3 Jahren) werden markiert (#255)
- Team-Ligazuordnung: Teams können zusätzlichen Ligen desselben Verbandes zugewiesen werden (#253)
- Saison-Wechsel: Admin kann die aktive Saison umstellen (neuer Endpunkt `PATCH admin/settings/current_season`)
- Saison anlegen: Admin kann neue Saisons anlegen (neuer Endpunkt `POST admin/settings/seasons`)

---

## [1.10.1] - 2026-05-11

### Behoben
- Schiri-Link: Server-Fehler beim Generieren behoben (`name` → `fullname`)
- Spielplan: Spiele konnten nicht gelöscht/gespeichert werden (URL-Bug durch falsche Operator-Precedenz)

### Verbessert
- Spielplan-Icons: Hover-Tooltips für alle Aktions-Buttons
- Spielberichts-Scan: Einstellung von Verbands- auf Landesverbands-Ebene verschoben
- Vereinsverwaltung: Hinweistext unter Kontakt-E-Mail entfernt

### Verbessert
- Spielplan-Icons: Hover-Tooltips für alle Icon-Buttons
- Spielberichts-Scan: Einstellung von Verbands- auf Landesverbands-Ebene verschoben

---

## [1.10.0] - 2026-05-11

### Neu
- Spielbericht: SBK und Admin sehen Bearbeitungszeitpunkt und -person des Spielberichts (#272)
- Spielbericht: Nachbearbeitungen nach Abschluss werden mit einem Hinweis angezeigt (#284)


---

## [1.9.0] - 2026-05-11

### Neu
- Spielorte-Verwaltung: SBK und Admin können Spielorte selbst anlegen (`POST admin/arenas`) und bearbeiten (`PATCH admin/arenas/:id`); Pflichtfelder Name und Stadt; Duplikatswarnung bei gleicher Stadt+Name oder gleicher Adresse (überschreibbar) (#270)

---

## [1.8.0] - 2026-05-11

### Neu
- Spielerfreigaben zurückziehen: SBK des abgebenden Landesverbands kann erteilte Spielerfreigaben pro Verein einzeln zurückziehen (PATCH `admin/transfer_requests/:id/revoke`). Beim Zurückziehen werden alle beantragten und erteilten Lizenzen des Spielers für Teams des freigegebenen Vereins auf „zurückgezogen" gesetzt, die Sekundärmitgliedschaft deaktiviert und Datum sowie Begründung für das Protokoll gespeichert. Der Datensatz bleibt erhalten und ist weiterhin einsehbar (#224)
- Vereinsinitiierter Transferprozess: VM des aufnehmenden Vereins kann einen Transferantrag per Spielersuche (Name + Geburtsdatum) stellen. Der abgebende Verein und anschließend der abgebende Landesverband (SBK) müssen bestätigen. Bei Vollzug werden alle Lizenzen auf „ungültig wg. Transfer" gesetzt, beide Vereine, der Spieler und die beteiligten SBKs per E-Mail informiert. Sekundäre Vereine (Zweitlizenzen/Freigaben) werden ebenfalls benachrichtigt.
- Spielplan: Spiele können auf einen anderen Spieltag verschoben werden (#191)
- Benutzerverwaltung (`GET/PATCH /api/v2/admin/users`, `POST /api/v2/admin/users/:id/trigger_password_reset`): Admin und SBK sehen alle Benutzer im eigenen Verband; VM sieht VM/TM des eigenen Vereins; Rollen-Toggle TM↔VM, Deaktivierung (nur SBK/Admin), Passwort-Reset-Mail ohne direktes Passwortsetzen (#197)
- Spieler deaktivieren: SBK und Admin können Spieler bei Vereinsaustritt deaktivieren (`POST admin/players/:id/deactivate`). Deaktivierte Spieler erscheinen nicht mehr in der aktiven Spielerliste des Vereins, bleiben aber im System erhalten. Beim Deaktivieren werden alle aktiven Vereinsmitgliedschaften (`valid_until`) und APPROVED/REQUESTED-Lizenzen (→ `DELETED`) geschlossen. Die Aktion ist auf Spieler beschränkt, deren Heimverein im zuständigen Spielbetrieb der SBK liegt (#286)
- Spielbericht: Freitext für besondere Ereignisse (Spielverzögerungen, technische Störungen etc.) erfassbar und öffentlich in den Spielinfos sichtbar (#199)

### Verbessert
- Schiedsrichter-Ansetzung: Beim Veröffentlichen einer RSK-Ansetzung wird `nominated_referee_string` des Spiels automatisch mit den Namen der angesetzten Schiedsrichter überschrieben (Format: `"LIZENZNR NACHNAME, Vorname / LIZENZNR NACHNAME, Vorname"`)

---

## [1.7.0] - 2026-05-09

### Neu
- Globale Lizenzliste für SBK/Admin: `GET /api/v2/admin/licenses.json` gibt alle Lizenzen einer Saison als flache Liste zurück, inkl. Erst-/Zweitlizenz-Kennzeichnung, Expresslizenz-Flag, Wettbewerbskontext und Dokumentenstatus-Platzhalter; filterbar nach Saison und Spielbetrieb (#193, #258, #268)

### Verbessert
- Lizenzstatus kann durch SBK nachträglich auf "beantragt" zurückgesetzt werden (`handle_license_request` erlaubt jetzt `license_status_id: 2`) (#198)

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
