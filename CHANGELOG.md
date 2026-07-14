# Changelog

Alle wesentlichen Änderungen am Saisonmanager werden hier dokumentiert.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), Versioning: [Semantic Versioning](https://semver.org/).

> **Patch** (1.0.**x**): Bugfixes · **Minor** (1.**x**.0): Neue Features · **Major** (**x**.0.0): Breaking Changes

---

## [Unreleased]

## [1.50.0] - 2026-07-14

### Neu

- **Öffentlicher Lizenzcheck: Vereinsname**: `GET user/referees/:id` liefert zusätzlich `verein` (Vereinsname des Schiedsrichters), damit der externe SR-Lizenzchecker (`sr.floorball.de`) den Verein direkt aus der API statt aus einer CSV anzeigen kann. `sr.floorball.de` wurde zu den erlaubten CORS-Origins ergänzt.

### Verbessert

- **Domain-Umzug auf saisonmanager.de**: Das produktive System ist künftig unter der bekannten Domain `saisonmanager.de` erreichbar (bisher `saisonmanager.org`). Alle generierten, nutzergerichteten Links (Passwort-Reset, Transfer- und Spielbericht-Links, Lizenzliste, Share-Links) zeigen über die zentrale `FrontendUrl`-Quelle nun auf `.de`. E-Mail-Absender/Reply-To und die SMTP-HELO-Domain wurden auf `@saisonmanager.de` bzw. `saisonmanager.de` umgestellt; der Lizenzcheck-Link in der Lizenz-Benachrichtigung zeigt jetzt auf `saisonmanager.de/lizenzcheck`. CORS erlaubt während der Übergangsphase weiterhin beide Domains.

## [1.49.1] - 2026-07-13

### Behoben

- **Team-Statistiken für vergangene Saisons waren leer**: `GET teams/:id/stats` filterte Torschützen, letzte und kommende Spiele stets auf `Setting.current_season_id`. Für Teams aus abgelaufenen Saisons (z. B. öffentliche Team-Seiten alter Ligen) lieferte das leere Ergebnisse, obwohl die Spieldaten vorhanden waren. Die Saison wird jetzt korrekt aus der eigenen Liga des Teams abgeleitet.
- **Verfahrensvorschlag ignorierte den Berichtsworkflow-Schalter**: `manual_proceeding_creation` erzeugte bei rotem-Karten-/Sonderereignis-Berichten immer einen Verfahrensvorschlag für die SBK, selbst wenn `report_form_email_enabled` (der Master-Schalter für den digitalen Berichtsworkflow) für den Landesverband deaktiviert war. `report_form_email_enabled` wird jetzt zuerst geprüft; ist der Workflow aus, bleibt es beim analogen Vor-Ort-Papierbericht.

## [1.49.0] - 2026-07-13

### Behoben

- **Legacy-Datenkorrektur: Nationalitäten** – Nach dem finalen Go-Live-Dump standen die Spieler-Nationalitäten flächendeckend als rohe Legacy-IDs in der DB (praktisch alle Spieler wurden als „Dänemark" statt „Deutschland" angezeigt). Neuer Rake `players:reapply_nation_fix` remappt sie auf das neue Schema (identisch zur Migration `20260415140000`: 3→4, 4→1, 6→6, 99→99, übrige→99). Nicht idempotent, daher mit Wiederholungssperre (bricht ab, wenn keine Legacy-Reste mehr vorhanden sind) und Dry-Run-Standard.
- **Legacy-Datenkorrektur: offene Vereinsmitgliedschaften** – Aus dem Import 2010–2014 stammende Mitgliedschaften standen ohne Enddatum („bis heute") in der Historie, obwohl der Spieler den Verein längst gewechselt hatte. Neuer Rake `players:close_legacy_memberships` setzt das Enddatum offener Legacy-Mitgliedschaften auf das exakte Startdatum des Folgevereins; ohne datierten Folgeverein bleibt die Mitgliedschaft offen. Kernlogik als `LegacyImport::MembershipCloser` (getestet), Dry-Run-Standard.

### Neu

- **Vollständige Lizenzhistorie im Spielerprofil**: `GET admin/players/:id.json` akzeptiert jetzt den Parameter `all_licenses=true` und liefert dann die komplette, saisonübergreifende Lizenzliste eines Spielers statt nur der aktuellen Saison. Ohne den Parameter bleibt das Verhalten unverändert (nur aktuelle Saison). Das Spielerprofil im Frontend nutzt dies, um die Lizenzen nach Saison gruppiert anzuzeigen.
- **Admin: Teams löschen**: Neue `DELETE admin/teams/:id`-Route für Admin/SBK (analog zur bisherigen `update_team`-Berechtigung). Löschen wird mit erklärender 422-Meldung abgelehnt, solange dem Team noch Spieler/Lizenzen, Spiele/Ergebnisse, Sperren, Schiri-Feedback oder sonstige verknüpfte Einträge (z.B. Spieltag-Bestätigungen) zugeordnet sind.

## [1.48.1] - 2026-07-13

### Verbessert

- **Vereins-/Team-Auswahl lädt deutlich schneller**: Der Endpunkt `GET user/clubs_and_teams` (befüllt u.a. die Verein-Zuweisung in der Benutzerverwaltung sowie Vereins-Dropdowns bei Spieler- und Benutzeranlage) litt unter einem N+1-Problem: Pro Verein wurden Teams, Logos, Ligen und Spielbetriebe einzeln nachgeladen – für Admins mit allen 315 Vereinen ~950 Datenbank-Abfragen und über 5 Sekunden Wartezeit, in der die Auswahlfelder leer wirkten. Teams der aktuellen Saison und alle Logos werden jetzt gesammelt vorgeladen (11 Abfragen, unter 0,6 Sekunden) – bei unverändertem Antwortformat.

## [1.48.0] - 2026-07-13

### Neu

- **Login per Benutzername oder E-Mail-Adresse**: Im Login-Feld kann jetzt neben dem Benutzernamen auch die hinterlegte E-Mail-Adresse eingegeben werden (`POST /login`). Der exakte Benutzername hat weiterhin Vorrang; eine E-Mail wird nur akzeptiert, wenn sie eindeutig genau einem Konto zugeordnet ist (die E-Mail-Spalte hat keine Eindeutigkeits-Constraint), und der Vergleich erfolgt unabhängig von Groß-/Kleinschreibung. Das Passwort-vergessen-Verfahren bleibt unverändert benutzernamensbasiert.

## [1.47.0] - 2026-07-13

### Verbessert

- **Selektive Team-Übernahme beim Kopieren einer Liga aus der Vorsaison**: Der Kopier-Endpunkt (`POST admin/leagues/:id/copy`) akzeptiert jetzt statt des Alles-oder-nichts-Schalters `include_teams` eine Liste `team_ids` mit genau den zu übernehmenden Teams der Quell-Liga. Eine leere Liste kopiert nur die Liga-Stammdaten ohne Teams; der alte `include_teams`-Boolean bleibt als Rückfallebene für Altclients erhalten. Die Auswahl wird serverseitig auf Teams der Quell-Liga eingeschränkt, sodass fremde Team-IDs nicht eingeschleust werden können. Kopierte Teams werden weiterhin unbestätigt (`approved: false`) angelegt (#69).

## [1.46.0] - 2026-07-13

### Neu

- **Lizenz-Dokumente pro Spieler mit Verbands-Sichtbarkeit**: Der Dokumenten-Endpunkt eines Spielers (`GET admin/players/:id/license_documents`) liefert jetzt zu jedem Dokument die zugehörige Dokumentart (Name, Gültigkeit) sowie den Verband/Spielbetrieb (`game_operation_id`, Name), sodass das Spielerprofil die Dokumente nach Landesverband/Spielbetrieb gruppiert anzeigen kann. Die Sichtbarkeit richtet sich nach dem Katalog-Scope der Dokumentart: Admin und bundesweiter SBK (FD) sehen alle Dokumente; ein verbandsspezifisch gescopter SBK sieht nur globale (bundesweite) Dokumentarten und die seines eigenen Verbandes – fremde Verbandsdokumente werden weder in der Liste ausgegeben noch per Direktabruf (`show`) zugänglich. Vereins- und Teammanager behalten den bisherigen Zugriff auf die Dokumente ihres Spielers.
- **Berichtsformular-E-Mail-Workflow pro Landesverband aktivierbar**: Ob das vom Schiedsrichter hochgeladene Berichtsformular automatisch per E-Mail an die VSK des Landesverbands versendet wird, lässt sich jetzt pro Landesverband über das neue Flag `report_form_email_enabled` (Standard: aus) steuern. Bisher wurde der Versand nur implizit dadurch gesteuert, ob eine VSK-Adresse hinterlegt war; ist der Workflow nicht aktiviert, wird kein Bericht mehr per E-Mail verschickt. Der manuelle Verfahrensvorschlag (`manual_proceeding_creation`) bleibt unverändert vorrangig.

### Behoben

- **Deaktivierte Spieler tauchten in Suche, Transfer- und Freigabe-Antrag auf**: Beim verlustfreien Duplikat-Merge bleiben zusammengeführte Profile absichtlich erhalten (deaktiviert, `merged_into_id` gesetzt). Sie waren aber weiterhin in der Spielersuche (`/verwaltung/spieler/suche`) sowie bei der Spieler-Auswahl für Transfer- und Freigabe-Anträge auffindbar. Bei gemergten Duplikaten konnte der Antragspfad (Suche per Name + Geburtsdatum) sogar das deaktivierte Zweitprofil statt des aktiven Master-Datensatzes zurückliefern. Beide Abfragen filtern jetzt über den bestehenden `Player.active`-Scope auf aktive Spieler; zusätzlich weisen Transfer-Erstellung und SBK-Direktzuweisung einen deaktivierten Spieler explizit ab, falls dessen ID direkt übergeben wird (#91).
- **Vereins-Auswahlliste für Admins/SBK mit mehreren Spielbetrieben leer**: In `user_clubs_and_teams` (Vereins-Dropdown u. a. in der Benutzerverwaltung) wurden die Spielbetriebs-IDs von Admin- und SBK-Berechtigungen in ein verschachteltes Array (`[[…], […]]`) geschrieben und anschließend an `GameOperation.find` übergeben. Für nicht-globale Rollen mit mehreren zugeordneten Spielbetrieben lieferte das keine Vereine (bzw. brach ab). Die IDs werden jetzt via `flatten!` entschachtelt, und `where(id:)` statt `find` verhindert einen Absturz, falls eine Berechtigung auf einen gelöschten Spielbetrieb verweist.

## [1.45.1] - 2026-07-13

### Verbessert

- **Spielerstatistik-Endpunkt deutlich schneller (Caching + Index)**: `GET players/:id/stats` (öffentliches Spielerprofil) berechnete bei jedem Aufruf die komplette Karriere neu (~3,7 s bei langer Spielhistorie). Die Statistik wird jetzt pro Spieler in zwei Teilen gecacht: abgeschlossene Saisons mit langer TTL (1 Woche), die laufende Saison mit kurzer TTL (15 Minuten) – neue Spielberichte erscheinen also weiterhin zeitnah. Wird ein bereits abgeschlossenes Spiel nachträglich korrigiert, invalidiert das den Spieler-Cache sofort (über den `after_commit`-Hook des Spiels), sodass Korrekturen – auch in abgeschlossenen Saisons – nicht bis zum TTL-Ablauf unsichtbar bleiben. Anzeige-Namen (Liga, Verband, Team) werden nicht mitgecacht, sondern frisch aufgelöst, damit Umbenennungen sofort greifen. Zusätzlich beschleunigt ein GIN-Index auf `games.players` die Spielersuche in den Aufstellungen; die Containment-Query nutzt dafür jetzt Top-Level-Containment (#86).

### Behoben

- **Schiedsrichterlizenz-Gültigkeit: Regeljahr-Stichtag (31.07.) und einheitliche Ableitung**: Alle 4 Jahre ist Regeljahr (2022, 2026, 2030, …) – in Regeljahren laufen Lizenzen am 31.07. ab, sonst am 30.09. Diese Regel kannte bisher keine der Gültigkeits-Ableitungen; außerdem rechnete die Import-Vorschau beim CSV-Upload fix mit Kursjahr + 1, das Anwenden im LV-Review dagegen mit Kursjahr + `validity_years` – Vorschau und Ergebnis wichen still voneinander ab. Jetzt leiten LV-Review und Anwenden beide über `RefereeLicenseLevel.gueltigkeit_for` ab (Ablaufjahr = Kursjahr + Gültigkeitsdauer, Stichtag 31.07./30.09. je nach Regeljahr); die Import-Vorschau nutzt dieselbe Regel, ist aber provisorisch, da die Gültigkeitsdauer erst mit der Stufenzuordnung im LV-Review feststeht (bis dahin Default-Dauer). Zusätzlich setzt eine Migration die Gültigkeitsdauer aller Lizenzstufen vom unveränderten Default 2 auf die gelebte Praxis 1 Jahr (Kurs 2025 → gültig bis 31.07.2026); abweichende Stufen können danach bewusst konfiguriert werden (#87).
- **Lizenzstufen- und Qualifikationstypen-Verwaltung war für Admins nicht bedienbar**: Seit der Einschränkung der Katalog-Pflege auf Admins (Frontend #7/#8) prüft die Oberfläche `permissions['admin']`, um die Buttons „Neu/Bearbeiten/Löschen" anzuzeigen. Dieser Schlüssel fehlte im ans Frontend gesendeten `permissions`-Hash (`permissions_items`), sodass die Buttons für **alle** Nutzer inkl. echter Admins ausgeblendet blieben. `permissions_items` liefert jetzt einen expliziten `admin`-Boolean. Admins müssen sich nach dem Deploy einmal neu anmelden, damit die aktualisierten Berechtigungen wirksam werden.

## [1.45.0] - 2026-07-09

### Neu

- **Schiedsrichter-Re-Sync aus der FD-Excel „Schiedsrichterliste 2025"**: Neue Rake-Tasks `referees2025:report` (Read-only-Abgleich DB vs. Excel: Feld-Abweichungen, Tester-Anlagen, fehlende Schiris), `referees2025:sync` (Upsert per Lizenznummer – setzt Tester-Änderungen an den Echtdaten zurück, ohne IDs/Verknüpfungen zu verlieren; löscht Tester-Anlagen ohne Verknüpfungen) und `referees2025:import_history` (historische Kurs-/Testergebnisse 2011–2025 als Course-Results, pro Jahr ein Import-Batch). Karriere-Regel: 5 Jahre ohne Lizenz = beendet – diese Schiedsrichter werden weder importiert noch angetastet. Die CSVs erzeugt `scripts/export_schiedsrichterliste_csvs.py` aus der Excel. Die veralteten Import-Skripte (`scripts/import_referees.rb` mit destruktivem `delete_all`, `scripts/update_referee_licenses.rb`, `lib/tasks/import_referees.rake` – alle referenzieren inzwischen entfernte Spalten) sind ersatzlos entfernt.

## [1.44.0] - 2026-07-09

### Neu

- **Liga aus Vorsaison kopieren (Saisonwechsel-Erleichterung)**: Neuer Endpoint `POST admin/leagues/:id/copy` (Berechtigung wie Liga-Anlage: Admin oder SBK des Quell-Verbands) kopiert die Liga-Stammdaten in die aktuelle Saison – `deadline` wird um +1 Jahr verschoben, die Quell-Liga als Vorsaison-Liga (`league_id_preseason`) verknüpft. Spieltage, Spiele und Ergebnisse werden bewusst nicht kopiert. Optional (`include_teams: true`) werden die Teams der Quell-Liga mit übernommen – mit `approved = false`, die Meldung muss also neu bestätigt werden; Teammanager-Zuordnungen müssen neu gesetzt werden. Frontend-Teil: floorballdeutschland/saisonmanager#41.

### Verbessert

- **Spielorte löschen und zusammenführen ist jetzt Admins vorbehalten**: Spielorte (Arenen) bleiben verbandsübergreifend geteilte Stammdaten, die jeder SBK wie bisher anlegen und bearbeiten kann. Die destruktiven Aktionen Löschen und Zusammenführen (das Zusammenführen hängt Spieltage anderer Verbände um) erfordern jetzt Admin-Rechte – SBK erhalten dort 403. Neuer Berechtigungsschlüssel `arena_manage_lifecycle` für die Oberfläche (#62).
- **Passmeister-Wallet-Anbindung entfernt**: Der digitale Schiedsrichterausweis als Apple-/Google-Wallet-Pass über den externen Dienst Passmeister wird nicht mehr angeboten (abgelöst durch den Schiri-Ausweis im Schiri-Portal). Entfernt wurden der `PassmeisterService`, der Endpoint `POST admin/referees/:id/wallet_pass`, die Mail `RefereeMailer#wallet_pass_issued` (inkl. Katalog-Eintrag in den E-Mail-Vorlagen; eine ggf. gepflegte Vorlage wird per Migration gelöscht), die Felder `wallet_pass_issued_at`/`wallet_pass_url` an den Schiedsrichtern (DB-Spalten inkl. Staging-Anonymisierung) sowie das Permission-Flag `referee_wallet`.

### Behoben

- **Sicherheit: Vereinsmanager-Zugriff auf Schiedsrichter ist jetzt auch serverseitig vollständig read-only (#60)**: Mit dem Wegfall des Wallet-Endpoints ist der letzte in #60 genannte Schreibpfad entfernt; `update` und `merge` bleiben für VM gesperrt (`can_access_referee?` mit `include_vm: false`, nur Admin/RSK/Ansetzer im Scope) – abgesichert durch neue Controller-Tests (VM: Lesen erlaubt, 403 auf `update`/`merge`).
- **Kleinere Berechtigungs- und Robustheitslücken aus dem Sicherheits-Review geschlossen (#64)**: Schiri-Löschung entfernt Benutzerkonten nur noch für Admins; Coach-Auswahl und Ansetzungs-Endpunkte respektieren LV-Scope bzw. das Feature-Flag `referee_assignment_enabled`; Vereins-, Team-, Liga- und Spiel-Verwaltungs-Reads sind auf die berechtigten Rollen/Verbände gescopt (Vereinsliste ohne `contact_email` für nicht-privilegierte Rollen); Banner-Verwaltung prüft den konkreten Spielbetrieb; ungenutzte/kaputte Endpunkte (`tests`-Scaffold, `GET /clubs`) entfernt; Batch-Trigger `update_start_end` ist Admin-only.
- **Auf-/Abstiegsregeln: SBK-Zugriff dauerhaft abgesichert (#63)**: Der eigentliche Fix (SBK mit passendem Verbands-Scope darf die Qualifikationsregeln einer Liga pflegen, analog zur Liga-Bearbeitung) ist bereits mit 1.43.0 ausgeliefert (PR #66). Nachgezogen sind jetzt die Controller-Tests, die das Verhalten absichern: SBK des eigenen Spielbetriebs darf Regeln anlegen/ändern/löschen, SBK eines fremden Spielbetriebs sowie Vereins-/Teammanager erhalten 403.
- **Hartcodierte Sonder-Nutzer für „Lizenz für Transfer ungültig setzen" entfernt (#64)**: Das Recht `player_set_license_to_transfer` (Lizenzstatus manuell auf `TRANSFER` setzen) war neben Admins an eine fest im Code hinterlegte Nutzernamen-Liste (`jho_admin`, `buettner_sbk`, `mguenther`) gebunden – fragil (Umbenennung/Neuanlage vererbte bzw. verlor das Recht still) und für die Rollenverwaltung unsichtbar. Die Sonderliste (`User#special_user`) ist entfernt; das Recht hängt jetzt ausschließlich an der Admin-Rolle (Menü-Flag **und** serverseitige Prüfung in `players#handle_license_request`). Betroffene Nutzer, die das Recht behalten sollen, brauchen künftig Admin-Rechte.

## [1.43.1] - 2026-07-09

### Behoben

- **Gruppentabellen zeigten alle Liga-Teams statt nur der Gruppen-Teams**: Seit dem Fix „Teams ohne Spiele in Ligatabelle anzeigen" wurden in Ligen mit Gruppenphase (z. B. Deutsche Meisterschaft Kleinfeld) sämtliche Teams der Liga in **jeder** Gruppentabelle vorbefüllt – gruppenfremde Teams standen dort mit 0 Spielen. Die Vorbefüllung greift jetzt nur noch für die Gesamttabelle; Gruppentabellen enthalten wieder ausschließlich die Teams, die in der Gruppe spielen (auch bei noch nicht beendeten Gruppenspielen).

## [1.43.0] - 2026-07-08

### Neu

- **Lizenz-Pflichtdokumente gelten jetzt saisonübergreifend am Spieler, mit zentralem Dokumentarten-Katalog**: Dokumente wie Unterstellungserklärung/Anti-Doping-Erklärung, Schiedsvereinbarung, Zustimmung der Erziehungsberechtigten oder das Sportärztliche Attest werden einmal am Spieler hochgeladen und gelten für alle künftigen Lizenzanträge – sie hängen nicht mehr an der einzelnen Lizenz. Neuer Katalog „Dokumentarten" (`/api/v2/admin/document_types`, Pflege: Admin überall, SBK für den eigenen Verband; globale Einträge gelten bundesweit): je Dokumentart optional Beschreibung, Vorlage zum Download, Gültigkeit (`einmalig` oder `je Saison`) und Altersgrenze (`required_below_age`, z. B. 18 = Zustimmung Erziehungsberechtigte, 16 = Attest). **Altersabhängige Dokumente werden zum Datum der Lizenzbeantragung geprüft.** Ligen wählen ihre Pflichtdokumente weiter über `required_documents` (jetzt Katalog-Keys statt Freitext; Bestand wird automatisch als Katalogeinträge übernommen). Die Lizenzansichten liefern pro Antrag die tatsächlich erforderlichen Dokumente (`required_documents` altersaufgelöst) und den Erfüllungsstand aus dem Spieler-Bestand.

### Entfernt

- **Online-Prüfungen (Onlineprüfungen im Saisonmanager) entfernt**: Die Funktion, mit der Schiedsrichter Prüfungen direkt im Saisonmanager ablegen (RSK legt Test + Fragenkatalog an, weist Schiris zu, Schiri absolviert die Prüfung mit Countdown), wird nicht mehr benötigt und ist entfernt (Models, Controller, Routen, DB-Tabellen `online_tests`/`online_test_questions`/`online_test_assignments`/`online_test_attempts`). Die Menüpunkte waren bereits seit Kurzem nach Einführung ausgeblendet, es gab keine produktiven Testdaten.
- **„Meine Historie" → „Prüfungsergebnisse" zeigt jetzt die eigenen Kurs-Import-Ergebnisse**: Der Tab bezog seine Daten bisher aus den (jetzt entfernten) Online-Prüfungen. `GET referee/history/tests` liefert stattdessen die eigenen `RefereeCourseResult`-Einträge aus dem CSV-Kurs-Import (Lizenzstufe, Gültigkeit, Kursstichtag, Status inkl. Ablehnungsgrund, Kursdaten Kurs 1/2 inkl. Testversion/Punkte/Ausbilder) – unabhängig vom Review-Status, damit auch offene/abgelehnte Fälle sichtbar sind.
### Verbessert

- **Spieler-Duplikat-Bereinigung: einzelne Gruppen vom automatischen Merge ausschließbar**: Der Rake-Task `players:merge_duplicates` versteht jetzt `EXCLUDE_IDS=<Survivor-IDs, kommagetrennt>` – Duplikat-Gruppen, deren kleinste ID dort aufgeführt ist, werden komplett übersprungen (auch die Geburtsdatum-Korrektur). Damit lassen sich unklare Fuzzy-Matches (z. B. deutlich abweichendes Geburtsjahr) zur manuellen Prüfung zurückstellen, während der Rest automatisch zusammengeführt wird.

### Behoben

- **Spieler deaktivieren/reaktivieren scheiterte bei Altdaten ohne Clubs/Lizenzen**: `Player#deactivate!` und `#reactivate!` warfen einen `NoMethodError`, wenn die JSONB-Spalte `clubs` oder `licenses` `nil` war (statt leerem Array) – dadurch konnten solche Alt-Profile weder deaktiviert noch beim Zusammenführen doppelter Spieler (`players:merge_duplicates`, Admin-Merge) aufgelöst werden. Beide Methoden initialisieren die Spalten jetzt defensiv mit `[]`.
- **Zusammenführen doppelter Spieler ist jetzt verlustfrei und legt in die kleinste ID zusammen**: Beim Zusammenführen (`Player#merge_into!`, Admin-Merge und Rake-Task `players:merge_duplicates`) gingen bisher Daten verloren bzw. blieben am aufgelösten Datensatz hängen – **Transfers, Transfer-Anfragen, Lizenzdokumente, Spieler-Änderungsanträge und Sperren** wurden nicht auf den verbleibenden Spieler umgehängt, und bei den Spieleinsätzen wurden **Auszeichnungen (`awards`) sowie das Legacy-Array-Format der Startaufstellung** nicht mitgezogen. Jetzt werden alle diese Referenzen sauber umgeschrieben (Unique-Index-Kollisionen bei aktivem Transfer-Antrag bzw. identischem Lizenzdokument werden übersprungen; der Datensatz verbleibt dann verlustfrei am deaktivierten Zweit-Profil und wird im Merge-Ergebnis bzw. Log ausgewiesen). Merges, bei denen beide Spieler in derselben Aufstellung stehen, werden verweigert bzw. übersprungen (statt einen doppelten Eintrag zu erzeugen). Lizenzen werden pro **Team + Saison** zusammengeführt (History gemergt statt dupliziert), unterschiedliche Saisons desselben Teams bleiben getrennt. Der Rake-Task legt nun konsistent in den Datensatz mit der **kleinsten ID** zusammen, erkennt neben Tagesabweichungen auch **Geburtsdatum-Tippfehler mit einer abweichenden Ziffer** (z. B. Jahr `1872` statt `1972`) und wählt das verbleibende Geburtsdatum nach Plausibilität (realistisches Jahr, sonst das frühere Datum).
- **Staging-Mails und -Links verwiesen auf das Produktivsystem**: Auf `saisonmanager.dev` zeigten Links in E-Mails (Passwort-Reset, Schiedsrichter-Account-Anlage, Transfer-Bestätigung, Spielbericht-Upload, Spielsekretariat, Lizenzliste, Schiri-Feedback u. a.) sowie öffentliche Spiel-URLs fälschlich auf `https://saisonmanager.org`. Ursache: Staging läuft mit `RAILS_ENV=production`, während die Frontend-Hosts hartcodiert bzw. nur an `Rails.env.production?` gekoppelt waren. Die Frontend-Basis-URL kommt jetzt zentral aus `FrontendUrl.base` und ist per `ENV['FRONTEND_BASE_URL']` überschreibbar (Fallback: Produktiv-Frontend in Produktion, lokaler Dev-Port sonst). Für die Produktion ändert sich nichts.
- **Ein einzelner unvollständiger Datensatz legte nicht mehr ganze geteilte Ansichten lahm (500 für alle Nutzer)**: Mehrere öffentliche bzw. für alle sichtbare Ansichten warfen einen Server-Fehler, sobald ein einzelner Datensatz unvollständig war – z. B. ein **Playoff-Platzhalterspiel ohne Heim-/Gastteam**, ein **Spiel ohne gepflegte Halle oder Startzeit**, eine **einseitig erfasste Aufstellung** (nur Heim oder nur Gast), eine **Lizenz ohne Historie bzw. ohne Antrags-/Genehmigungseintrag** oder eine **unbekannte Nation-ID**. Da diese Ansichten über die gesamte Liga bzw. das gesamte Spiel iterieren, riss ein einziger solcher Datensatz die komplette Ansicht für alle Nutzer ab. Betroffen und jetzt abgesichert (nur defensive nil-/Typ-Prüfungen, keine Änderung der Ausgabe bei vollständigen Daten):
  - **Tabelle** (`/leagues/:id/table`, gruppierte Tabelle): Platzhalterspiele ohne Teams werden bei der Ergebnisauswertung übersprungen statt `nil.id` aufzurufen.
  - **Spielplan** (`schedule`, `game_day_schedule`): Sortierung ist nun robust gegen fehlende Datums-/Startzeit-Werte (kein `ArgumentError` mehr beim Vergleich `nil`/String).
  - **Scorer-Auswertung / Ticker / Spielansicht**: einseitige Aufstellungen (`players` `nil`/`{}`/nur Heim oder nur Gast), Platzhalterspiele ohne Teams, Ereignisse ohne Zeit/Periode sowie fehlende `last_item`-Ergebnisse führen nicht mehr zum Absturz; Ergebnisberechnung sortiert Ereignisse nun korrekt nach `row` (JSONB-String-Key statt Symbol) und vergleicht Perioden typsicher.
  - **Lizenzlisten** (Liga- und Team-Lizenzen): Lizenzen ohne Historie oder ohne Antrags-/Genehmigungseintrag sowie gelöschte/fehlende History-Ersteller (`User.find` → `find_by`) brechen die Liste nicht mehr ab.
  - **iCal-Export** (`.ics`): Spiele ohne hinterlegte Halle bzw. ohne gültiges Start-/Enddatum brechen den Kalender-Export nicht mehr ab.
  - **Nation-Anzeige**: eine nicht im Katalog hinterlegte `nation_id` liefert `nil` statt eines Server-Fehlers.
### Verbessert

- **Geburtsdatum ist jetzt eine echte Datums-Spalte**: `players.birthdate` war historisch ein Textfeld; Altersprüfungen (Liga-Spielberechtigung, Jugend-Kennzeichnung im Spielbericht, Minderjährigen-Erkennung) mussten den Wert bei jeder Verwendung defensiv parsen. Die Migration normalisiert den Altbestand deterministisch (deutsches Format → ISO, Leerwerte/MariaDB-Nulldaten → leer) und bricht bei nicht eindeutig lesbaren Werten ab, statt Geburtsdaten still zu verwerfen – zur Vorab-Analyse gibt es `rake players:birthdate_format_report`. Für API-Antworten ändert sich nichts (Datumsformat bleibt `JJJJ-MM-TT`). Vorarbeit für altersabhängige Lizenz-Pflichtdokumente.
- **Lizenzstufen und Qualifikationstypen: Pflege jetzt Admin-only**: Beide Kataloge gelten bundesweit (Lizenzstufen steuern u. a. die Gültigkeits-Ableitung beim Kurs-Import, Qualifikationstypen die Coach-Auswahl bei der Ansetzung – für alle Verbände gleich). Anlegen/Ändern/Löschen war bisher auch jedem LV-RSK erlaubt, was einem einzelnen Landesverband ungewollten Einfluss auf bundesweite Standards gab. Lesezugriff (für RSK/SBK/Ansetzer, die die Listen z. B. im Schiri-Bearbeiten-Formular brauchen) bleibt unverändert.
### Behoben

- **SBK bekam 403 beim Anlegen/Ändern/Löschen von Auf-/Abstiegsregeln (Qualifikationsregeln)**: Der Regel-Block in der Liga-Bearbeitung ist für dieselben Nutzer sichtbar, die die Liga selbst bearbeiten dürfen (Admin und SBK im Spielbetrieb der Liga), das Backend ließ aber bislang nur Admin durch. `Admin::LeagueQualificationsController` prüft jetzt dieselbe Berechtigung wie das Bearbeiten der Liga selbst (`League#user_permissions` → `:update_league`).
- **Sicherheit: Vereinsmanager konnte Schiedsrichter bearbeiten, zusammenführen und Wallet-Ausweise ausstellen**: Für den VM war in `Admin::RefereesController` nur Lesezugriff (`vm/referees#index`) vorgesehen, das Backend erlaubte ihm über `can_access_referee?` aber zusätzlich `update` (inkl. E-Mail-Adresse und Gast-Flag), `merge` (irreversibles Zusammenführen zweier Schiris) und `wallet_pass` für Schiris seines Vereins. `can_access_referee?` schließt den VM-Zweig jetzt für diese drei Schreibaktionen aus (`include_vm: false`); Lesezugriff (`show`/`games`/`club_stats`) bleibt für VM unverändert.
- **Fehlende Ressourcen-Scope-Prüfungen in Admin-Endpunkten (IDOR)**: Mehrere Admin-Endpunkte prüften zwar die Rolle des Nutzers, aber nicht, ob die konkret angefragte Ressource in seinem Zuständigkeitsbereich liegt. Betroffen und behoben:
  - **Spieler-Detaildatensatz (`GET admin/players/:id`)**: War nur durch „eingeloggt" geschützt – jeder angemeldete Nutzer (auch ein Teammanager oder VM eines beliebigen Vereins) konnte den vollständigen Admin-Datensatz **jedes** Spielers (u. a. Geburtsdatum, Lizenz- und Vereinshistorie) abrufen. Jetzt greift dieselbe Spieler-Scope-Prüfung wie bei den übrigen spielerbezogenen Aktionen (`can_manage_player?`): Admin sowie SBK/VM/TM nur für Spieler im eigenen Zuständigkeitsbereich.
  - **Spieler ändern (`POST admin/players`, Update-Zweig)**: Die Berechtigung wurde gegen `params[:club_id]` geprüft, aber nie verifiziert, dass der über `params[:id]` geladene Spieler diesem Verein überhaupt angehört. Ein SBK (nur Admin/SBK erreichen diesen Zweig, siehe `Club#user_permissions`) konnte so mit einer eigenen Vereins-ID die Stammdaten (Name, Geburtsdatum …) **beliebiger** Spieler überschreiben. Der Spieler muss jetzt Mitglied des angegebenen Vereins sein, sonst 403.
  - **Spielsperren (`admin/players/:player_id/suspensions`)**: Ein nicht global gescopter SBK konnte Spieler **bundesweit** sperren/entsperren. Der SBK ist jetzt auf Spieler seines Spielbetriebs beschränkt (Admin bleibt global).
  - **Transferantrag-Detail (`GET admin/transfer_requests/:id`)**: Die Liste war scope-gefiltert, der Einzelabruf nicht – ein VM konnte fremde Transferanträge (inkl. Spieler-Geburtsdatum) über die ID lesen. Der Einzelabruf spiegelt jetzt exakt die Sichtbarkeit der Liste (Admin/SBK-Spielbetrieb/eigener Verein).
  - **Lizenzgebühren-Berechnung (`GET license_fees/:id`)**: Die Übersicht war auf wenige Abrechnungs-Accounts beschränkt, der Download einer einzelnen Berechnung (JSON/CSV/XLSX) hingegen für **jeden** Login abrufbar. Der Einzelabruf nutzt jetzt dieselbe Whitelist wie die Übersicht.
  - **Schiri-Bericht (`GET games/:game_id/referee_report`)**: Der Upload war auf die angesetzten Schiris beschränkt, der Abruf der Bericht-Blob-URL jedoch für jeden Login möglich. Die Blob-URL (`uploaded: true` + `url`) liefert der Endpoint jetzt nur noch an Admin, SBK im Spielbetrieb des Spiels sowie die angesetzten Schiris aus; alle anderen erhalten `{ uploaded: false }` statt eines 403 (die Spieldetailseite ruft den Endpoint für jeden Login auf – ein 403 hätte dort einen Fehler-Popup + Zwangsredirect ausgelöst).
- **Vereinsmanager konnte verbandsübergreifend jedes Spiel bearbeiten**: In `GamesController#set_string` (Live-Erfassung) lieferte der erste `intersection(...)`-Ausdruck der VM-Prüfung ein Array zurück; ein leeres Array ist in Ruby truthy, sodass die `||`-Kette kurzschloss und **jeder** VM Ereignisse **jedes** Spiels (auch anderer Landesverbände) setzen konnte. Der Treffer wird jetzt mit `.present?` ausgewertet; Platzhalter-Spiele ohne Heim-/Gastmannschaft werden nil-sicher behandelt. Im selben Zug wurde die bislang ungescopte SBK-Prüfung in `set_string` auf den Spielbetrieb des Spiels beschränkt (Admin bleibt global) – bisher konnte auch ein Landesverbands-SBK jedes Spiel bundesweit bearbeiten.
- **500 statt 422 beim Anlegen eines Spielers mit unvollständigen Daten**: In `POST admin/players` (Anlage) führten fehlende `first_name`/`last_name`/`birthdate` bzw. ein ungültiges Datum zu einem Serverfehler (`nil.downcase` / ungültiges `to_date`). Fehlende Pflichtfelder und ungültige Geburtsdaten liefern jetzt eine `422`-Meldung.
- **Sicherheit: Passwort-Reset ohne Token konnte fremde Konten übernehmen**: Der öffentliche Endpoint `reset_password_token` suchte den Nutzer per `find_by(password_reset_token: params[:reset_token])`. Fehlte der Token, matchte `find_by(password_reset_token: nil)` den ersten Account ohne Token (i. d. R. der Admin), sodass ein unauthentifizierter Request ohne Token dessen Passwort setzen konnte; ein abgelaufener Token führte zudem zu `nil.update` (500). Leere Tokens und ein fehlender Treffer werden jetzt vorab als „Ungültiger oder abgelaufener Link" (404) abgewiesen.
- **Sicherheit: `GET /users` gab Passwort-Hashes aller Konten preis**: Der Legacy-Endpoint war nur durch `authenticate_user` geschützt und serialisierte `User.all` ungefiltert – jeder eingeloggte Nutzer (auch ein Teammanager) erhielt `password_digest`, `password_reset_token`, E-Mail und Berechtigungen aller Konten. Der Endpoint ist jetzt auf Admin/SBK beschränkt und liefert `password_digest`/`password_reset_token` nicht mehr aus.
- **Sicherheit: RSK-Rollenausweitung auf VM-/TM-Konten unterbunden**: Ein reiner Landesverbands-RSK konnte über die Benutzerverwaltung E-Mail-Adresse eines VM-/TM-Kontos ändern und einen Passwort-Reset auslösen und so das Konto samt VM-/TM-Rechten übernehmen. `require_admin_for_elevated_target!` behandelt VM/TM jetzt auch als geschützte Zielrollen, wenn der verwaltende Nutzer nur RSK-Rechte (ohne Admin/SBK/VM-Scope) hat; der Schutz greift zusätzlich beim Löschen. Team-Zuweisungen durch Nicht-VM-Manager außerhalb des eigenen Scopes werden abgelehnt. Admin, SBK und VM verwalten VM/TM weiterhin regulär im Rahmen ihres Scopes.
- **Zentrales Fehler-Handling: nicht behandelte Fehler und veraltete IDs liefern jetzt sauberes JSON statt „Server-Fehler"**: Bislang hatte der `ApplicationController` nur einen einzigen `rescue_from` (für ungültige CSRF-Token). Mit `config.consider_all_requests_local = false` in Produktion führte das dazu, dass ein `ActiveRecord::RecordNotFound` (z. B. bei veralteten, gelöschten oder fremden Datensatz-IDs) die statische HTML-Seite `public/404.html` auslieferte – die das Angular-Frontend nicht als JSON parsen kann – und dass **jede** sonstige Ausnahme (`NoMethodError`, `ArgumentError`, `TypeError`, `PG::Error`, versehentliche `save!`/`update!`/`create!`-Fehler) als generischer 500 „Server-Fehler" im Frontend landete. Der Controller behandelt Fehler jetzt zentral und antwortet konsistent im App-Format `{ success: false, message: ... }`: `ActiveRecord::RecordNotFound` → **404** („Nicht gefunden."), `ActionController::ParameterMissing`/`UnpermittedParameters` → **422**, `ActiveRecord::RecordInvalid` → **422** (inkl. `errors`), und ein Last-Resort-Handler für alle übrigen `StandardError` → **500** („Server-Fehler."), der den Fehler samt Backtrace protokolliert und an Sentry meldet. In Entwicklung/Test wird der generische Fehler weiterhin durchgereicht (Stacktraces bleiben sichtbar, Test-Suiten werden nicht maskiert). Das behebt einen Großteil der von Nutzern gemeldeten „Server-Fehler"-Popups.

## [1.42.0] - 2026-07-03

### Neu

- **Erst-/Zweitlizenz im GF-Erwachsenenbereich: manuelle Zuordnung statt Heuristik**: Ob eine Großfeld-Lizenz Erst- oder Zweitlizenz ist, hat weder mit der Ligahöhe noch mit dem Beantragungszeitpunkt zu tun – es ist die Wahl des Spielers und betrifft die Spielberechtigung (mit der Zweitlizenz ist z. B. der FD-Pokal ausgeschlossen). Die bisherige automatische Ableitung (`is_zweitlizenz`: höchste GF-Liga = Erstlizenz) ist daher entfernt. Stattdessen wird die Zuordnung jetzt manuell dokumentiert und im Lizenz-Eintrag gespeichert (`gf_role`: `erstlizenz`/`zweitlizenz`, mit Historie `gf_role_history`): Die SBK kann sie **bei der Lizenz-Genehmigung** setzen (wird die neue Lizenz Erstlizenz, wird die bestehende GF-Lizenz im selben Wettbewerb automatisch zur Zweitlizenz) und später **im Spielerprofil** ändern (neuer Endpoint `POST admin/players/:id/set_gf_license_role`). Die Zuordnung gilt pro Wettbewerb (GF Erwachsene, getrennt männlich/weiblich – Damen können so je Wettbewerb eine Erstlizenz haben) und nur für GF-Erwachsenen-Ligen (nicht U-Altersklassen). Ein **Tausch** ist einmal pro Saison erlaubt (Umgehungsschutz der Zweitlizenz-Beschränkungen); weitere Täusche kann nur ein Admin durchführen. Alle Wechsel sind mit Nutzer und Zeitpunkt nachvollziehbar. Bestehende Lizenzen starten ohne Zuordnung („nicht zugeordnet") – eine Alt-Befüllung entfällt bewusst, da die Lizenzen zum 15.07.2026 verfallen. Die Anzeige „Hauptlizenz/Zusatzlizenz" (`license_type`) bleibt davon unberührt und wird weiterhin automatisch bestimmt.

## [1.41.2] - 2026-07-03

### Behoben

- **Straf-Grund alter Spielberichte wurde nicht mehr angezeigt**: Historische Spiele referenzieren teils Alt-Strafcodes (`penalty_code_id` 1–6: „Behinderung", „Stockschlag", „Haken", „Halten", „Hoher Stock", „Unsportliches Verhalten"), die im Katalog nur eine Bezeichnung unter `name` tragen – ohne 3-stelligen `code`/`description`. Der Spielbericht-Serializer las jedoch nur `description`, sodass der Straf-**Grund** in ~3.460 Alt-Ereignissen leer blieb (nur die Dauer, z. B. „2 Minuten", erschien). `penalty_reason` fällt jetzt auf `name` zurück und zeigt den Grund wieder an. `Game.freeze_penalty_labels` friert diese Bezeichnung als `penalty_code_description` ins Event ein, sodass der Grund auch nach dem Entfernen des Katalog-Eintrags erhalten bleibt.
- **Vereinsmanager: „Berechtigungsfehler" nach Lizenzantrag blockierte die Lizenzverwaltung**: Nach dem Beantragen einer Lizenz lud das Frontend im Hintergrund die Lizenzdokumente des Spielers (`GET /api/v2/admin/players/:id/license_documents`). Die dortige VM-Berechtigungsprüfung war jedoch enger als die Prüfung beim Beantragen: Sie verglich die vom VM verwalteten Vereine nur mit den Vereinsmitgliedschaften des **Spielers** und zählte dabei ausschließlich Mitgliedschaften mit `valid_until = NULL` als aktiv. Dadurch schlug sie u. a. bei Spielgemeinschafts-/Syndikats-Teams (Spieler eines Partnervereins) und bei zukünftig datiertem `valid_until` mit **403** fehl – der globale Fehler-Interceptor zeigte „Berechtigungsfehler" und leitete auf die Startseite um, sodass sich keine weitere Lizenz mehr lösen ließ. Die Prüfung (`vm_for_player?`) ist jetzt konsistent zu `players#request_license`: Der VM ist berechtigt, wenn er einen aktuell gültigen Verein des Spielers **oder** den Verein/Syndikat-Verein des Teams verwaltet, zu dem die Lizenz gehört; die `valid_until`-Aktiv-Logik (`NULL` oder in der Zukunft) entspricht nun dem übrigen System.
- **Schiri-Feedback an die tatsächlich eingesetzten Schiedsrichter verknüpfen**: Ein abgegebenes Feedback wurde bisher ausschließlich über die **Ansetzung** (`nominated_referee_ids`) mit einem Schiedsrichter verknüpft. Wurde ein Spiel nicht über das Ansetzungs-Modul angesetzt (in der 1. FBL der Regelfall), landete das Feedback **ohne Schiri-Bezug** und tauchte auf keinem Schiri-Profil auf – obwohl der pfeifende Schiri im Spielbericht eingetragen ist. Das Feedback wird jetzt an die **tatsächlich im Spielbericht eingesetzten Schiedsrichter** gehängt, aufgelöst über die Lizenznummer aus `referee1_string`/`referee2_string` bzw. der Live-Erfassung `referee_ids` (neu: `Game#officiating_referees`). Die Ansetzung dient nur noch als Fallback. Für Altbestände verknüpft der neue Rake-Task `referee_feedback:backfill_referees` bereits abgegebene, unverknüpfte Feedbacks nachträglich.

### Verbessert

- **Aufräumen der verwaisten Alt-Strafcodes**: Der neue Rake-Task `penalty_codes:cleanup_legacy` (mit `DRY_RUN=1`) friert den Grund-Text der Alt-Strafcodes (name-only, kein `code`, nicht aktiv) in alle referenzierenden Spiel-Ereignisse ein und entfernt anschließend die dann verwaisten Katalog-Einträge. Ein Sicherheits-Abbruch verhindert das Löschen, falls ein Ereignis nicht eingefroren werden konnte. Ergebnis: der Strafcode-Katalog enthält nur noch die gepflegten, aktiven 9xx-Codes, ohne dass historische Spielberichte Informationen verlieren.
- **Kanonische, stabile Verknüpfung der eingesetzten Schiedsrichter am Spiel**: Neue Spalte `games.officiating_referee_ids` speichert die tatsächlich eingesetzten Schiris als Referee-PKs (analog `nominated_referee_ids` für die Ansetzung). Bisher lagen die eingesetzten Schiris nur als Freitext (`referee1/2_string`) bzw. als Lizenznummern (`referee_ids`) vor – Lizenznummern sind über den Schiri-Merge wanderbar und daher kein stabiler Schlüssel. `GamesController#set_referee` löst beim Eintragen die Lizenznummer direkt auf die Referee-PK auf und speichert sie mit; `Game#officiating_referees` bevorzugt die PK-Spalte (Fallback: Lizenz-Auflösung für Bestandsspiele). Beim Schiri-Merge werden die PKs mit umgeschrieben. Der Rake-Task `referees:backfill_officiating_ids` befüllt Bestandsspiele nach. Erster Schritt zur Vereinheitlichung der Schiri-Identität am Spiel (Issue #45); Umstellung der Lese-/Anzeigepfade und der Eingabe-UI folgt.

## [1.41.1] - 2026-07-02

### Behoben

- **LV-RSK konnte neue Schiedsrichter anlegen**: Die Schiedsrichterkommission eines Landesverbands (RSK LV) verwaltet nur den Bestand des eigenen Verbands und darf keine neuen Schiedsrichter anlegen – konnte es aber. Das Anlegen (`POST /api/v2/admin/referees`) und die automatische Lizenznummern-Vorbelegung (`next_lizenznummer`) sind jetzt auf Vollzugriff (Admin + FD-RSK) beschränkt; das Frontend blendet den „Neuer Schiedsrichter"-Button entsprechend aus (Permission `referee_can_create`). Das **Anlegen eines Benutzerkontos für einen bestehenden Schiri** (`create_user`) bleibt bewusst auch dem LV-RSK erlaubt und hängt nun an der eigenen Permission `referee_can_create_user`.

### Verbessert

- **Schiedsrichter-Tags: FD pflegt einen eigenen, privaten Tag-Bestand**: Bisher wurden Tags, die ein FD-RSK/-Ansetzer anlegt, als *globale* Tags (`game_operation_id` NULL) gespeichert und waren damit für alle Landesverbände sichtbar – weil die FD-Rolle intern auf den globalen Scope `0` abgebildet wird. Jetzt wird für einen FD-Nutzer die tatsächliche Spielbetriebs-ID aus den Roh-Permissions herangezogen, sodass FD-Tags an den FD-Spielbetrieb gebunden und für andere Landesverbände **nicht** mehr sichtbar sind. Jeder verbandsgebundene Nutzer (LV wie FD) sieht und verwaltet nur die eigenen Verbands-Tags plus globale; globale Tags (verbandsübergreifend sichtbar) legt/verwaltet ausschließlich der Admin. Die Regel gilt konsistent für Sichtbarkeit (`GET admin/referee_tags`), Verwaltung (create/update/destroy) und Zuweisung an Schiedsrichter (`tag_ids`). Bereits vorhandene, als global angelegte FD-Tags bleiben global und müssen bei Bedarf einmalig neu angelegt werden.
- **SMTP-Ziel per ENV konfigurierbar (Staging-Mail-Catcher)**: Die produktive Mailer-Konfiguration nutzt jetzt `SMTP_ADDRESS`/`SMTP_PORT`, falls gesetzt, und schickt dann ohne Auth/TLS an dieses Ziel – damit kann die Staging-Umgebung (`saisonmanager.dev`) alle E-Mails in einen lokalen Catcher (Mailpit) statt an echte Empfänger leiten. Ohne `SMTP_ADDRESS` bleibt das Office-365-Setup unverändert. Zusätzlich anonymisiert der neue Rake-Task `staging:anonymize` einen Prod-Klon auf der Staging-DB (Namen, E-Mails, Geburtsdaten, Pass-/Sicherheitsnummern) und setzt Test-Logins; er läuft per Schutzprüfung ausschließlich gegen die Staging-DB.
- **Schiri-Feedback-Benachrichtigung beim Spielbericht-Abschluss**: Die Info-Mail an die Teammanager wird jetzt ausgelöst, sobald der **Spielbericht abgeschlossen** wird (Statuswechsel auf `match_record_closed`/`finalized`), statt zeitgesteuert 24 Stunden nach Anpfiff. Passend dazu öffnet auch das **Feedback-Formular mit dem Bericht-Abschluss** (bisher: frühestens 24 h nach Anpfiff) – Mail und Ausfüllbarkeit sind damit konsistent, und der Teammanager kann sofort loslegen. Ausgelöst direkt in `GamesController#set_game_status`; die gemeinsame Logik (Fälligkeit, Teammanager-Ermittlung inkl. `receive_info_mails`-Opt-out, Idempotenz über `games.referee_feedback_notified_at`) liegt neu im Service `RefereeFeedbackNotifier`. Der stündliche Rake-Task `referee_feedback:notify_available` nutzt denselben Service und dient nur noch als Fallback (z. B. für Ligen, die erst nachträglich per `referee_feedback_enabled` freigeschaltet werden). Die Feedback-Übersicht (`GET /api/v2/user/referee_feedbacks`) listet nur noch Spiele mit abgeschlossenem Bericht.

## [1.41.0] - 2026-06-30

### Neu

- **Öffentlicher Endpunkt „Vereine mit Teams je Saison"**: Neuer key-geschützter Endpunkt `GET /api/v2/game_operations/:id/clubs/:season_id` (sowie ohne `:season_id` für die aktuelle Saison) liefert alle Vereine eines Spielbetriebs samt der Teams, die in der angegebenen Saison im Einsatz sind. Die Vereinsliste wird aus den tatsächlich gemeldeten Teams abgeleitet (inkl. Spielgemeinschafts-Vereinen über `syndicate_clubs`), nicht aus der reinen Vereinsregistrierung. Ausgabe analog zu `game_operations/:id/leagues/:season_id` per `X-Api-Key`; `contact_email` und interne Felder werden über die neue `Club#public_hash`-Variante nicht ausgeliefert. Schließt die bisherige Lücke, dass es keinen direkten Weg gab, die Verein-↔-Team-↔-Saison-Zuordnung auszulesen.
- **Schiedsrichter-Tags für die Ansetzung**: Ansetzer (und RSK/Admin) können Schiedsrichter frei mit Tags versehen (z. B. „Spitzenschiri", „Finalspiel-tauglich") und so ihren Bestand kategorisieren. In der Ansetzungs-Ansicht lässt sich die Liste der verfügbaren Schiris per Tag vorfiltern – analog zu den bestehenden Lizenzstufen-Chips und dem „kurzfristig mobil"-Filter. Der Tag-Katalog (`GET/POST/PUT/DELETE /api/v2/admin/referee_tags`) ist pro Spielbetrieb gescopt: ein LV-Ansetzer pflegt seine eigenen Tags, globale Tags (ohne Spielbetrieb) sind allen sichtbar und nur von Admin/FD verwaltbar. Tags werden über `tag_ids` beim Schiri-Update zugewiesen sowie in `admin/referees` (inkl. neuem `tag_id`-Filter) und im Ansetzungs-Endpoint `referee_assignments/available` mitgeliefert. Datenmodell analog zu den Zusatzqualifikationen über Katalog (`referee_tags`) + Zuordnung (`referee_taggings`); beim Zusammenführen zweier Schiedsrichter werden die Tags mit übernommen.

### Behoben

- **Teammanager konnten den Spielbericht nicht pflegen**: Der Bearbeiten-Tab im Spielbericht wird im Frontend nur bei der Permission `edit_game_report` angezeigt. `Game#user_permissions` vergab diese aber nur an Admin, SBK und den Vereinsmanager des ausrichtenden Vereins – **nie an Teammanager** (offener `TODO`-Kommentar). Dadurch sah ein TM keinerlei Eingabemöglichkeit, obwohl die einzelnen Schreib-Aktionen (Aufstellung über `can_edit_lineup?`, Spielinfos über `set_string`) TM längst zuließen. `edit_game_report` wird jetzt auch an den TM des Heim- bzw. Gastteams vergeben, sodass UI-Gate und Aktions-Autorisierung wieder zusammenpassen.

## [1.40.1] - 2026-06-28

### Verbessert

- **Zusammengesetzter Index auf `game_days (league_id, number)`** (Issue #27): `League#games`/`#game_day_schedule` filtern Spieltage über `league_id` (und `number`) – der heißeste Lesepfad, seit #25 Tabelle/Scorer beim Cache-Miss neu aufbaut. Bisher war nur `league_id` allein indiziert. Der neue Composite-Index bedient beide Fälle (kombinierte Filterung und – via Leftmost-Prefix – reine `league_id`-Lookups); der dadurch redundante Einzelindex auf `league_id` entfällt.
- **N+1-Queries in Lizenzlisten und Spielplan-/Spieltagsansicht beseitigt** (Issue #26): `League#licenses` (Lizenzliste je Liga, über `admin/licenses` je Liga erneut aufgerufen) lud die Spieler bisher mit einer separaten SQL-Query **pro Team**. Neu sammelt `Player.find_by_team_ids` alle Teams einer Liga in **einer** Query (Beispiel: 8 Teams → von 8 auf 1 Query). `GameDay#full_hash(with_games: true)` (Spieltagsansicht/`admin_game_schedule`) und `League#schedule`/`#games` (öffentlicher Spielplan) laden Heim-/Gastteam samt Verein bzw. Spieltags-Halle/-Verein jetzt gebündelt vor (`includes`/`inverse_of`), statt sie pro Spiel nachzuladen. Zur laufenden Erkennung weiterer N+1 ist das `bullet`-Gem in Development aktiviert. Regressions-Tests sichern die Query-Anzahl ab.
- **Historische Daten self-contained – Straf-Labels eingefroren**: Spiel-Ereignisse speichern beim Erfassen jetzt die aufgelösten Straf-Labels (`penalty_mapping`, `penalty_name`, `penalty_code`, `penalty_code_description`) direkt im `events`-JSONB. `Game#penalty_mapping`/`#penalty_mapping_string`/`#penalty_reason` bevorzugen diese gespeicherten Werte und lösen nur für Alt-Ereignisse ohne Label noch live aus `Setting.penalties`/`penalty_codes` auf. Dadurch bleiben alte Spielberichte korrekt lesbar, **auch wenn Strafcodes später deaktiviert oder entfernt werden** – die bisher nötige Praxis, Codes nur über `active: false` zu „archivieren", wird damit überflüssig. Idempotenter Backfill für Bestandsspiele: `rake events:freeze_penalty_labels` (DRY_RUN=1 zum Testen).
- **Scorerliste self-contained**: Die Scorerliste (`League#scorer`) bezieht Spielernamen jetzt aus dem Spielbericht-Snapshot (`players`-JSONB) statt aus einem Live-`Player`-Lookup. Ein nachträglich umbenannter, zusammengeführter oder gelöschter Spieler verändert damit alte Scorerlisten nicht mehr; gelöschte Spieler fallen außerdem nicht mehr **still** aus der Liste (vorher `reject!` auf fehlende `Player`-Records). Bilder werden weiterhin best-effort live ergänzt, der Name aus dem Player-Datensatz dient nur noch als Fallback für sehr alte Importe ohne Snapshot-Namen.
- **Punktekorrekturen & Liga-Anzeigenamen an der Liga**: Punktekorrekturen liegen jetzt als Spalte `leagues.point_corrections` an der jeweiligen Liga (vorher global in `Setting.point_corrections`, keyed by `league_id`); `League#empty_table_item` liest sie von dort und fällt für noch nicht migrierte Ligen auf den Setting-Wert zurück. Zusätzlich werden Klassen-/Kategorie-Anzeigenamen (`league_class_name`/`league_category_name`) beim Anlegen einer Liga aus `Setting` eingefroren und additiv in `League#full_hash` ausgeliefert, damit eine spätere Umbenennung in `Setting` alte Ligen nicht rückwirkend verändert. Backfill für Bestandsligen: `rake leagues:freeze_labels` (DRY_RUN=1 zum Testen). (`Setting.league_category` ist nun nil-sicher, analog zu `league_class`.)

## [1.40.0] - 2026-06-26

### Behoben

- **Spielplan-Server-Fehler bei Spielen ohne Halle**: `GET /leagues/:id/schedule.json` (Spielplan-/„Alle Spiele"-Ansicht) lieferte `500`, sobald ein Spiel einen Spieltag ohne zugeordnete Halle hatte – `Game#schedule_item` griff mit `game_day.arena.name`/`.address`/`.schedule_item` ohne Safe-Navigation zu, und der `NoMethodError` ließ den gesamten Spielplan fehlschlagen. Jetzt `game_day.arena&.…` analog zum Spiel-Detail (`full_hash`). Betraf v. a. importierte Altdaten-Spiele.
- **Fehlende Spielernamen bei importierten Altdaten-Spielen**: Der Legacy-Import (`LegacyImport::Transformer.build_players`) schrieb die Aufstellungs-Namen unter `first_name`/`last_name`, während Lesepfad und Frontend (`fullName`-Pipe) – wie der Live-Erfassungspfad `GamesController#add_player_to_lineup` – `player_firstname`/`player_name` erwarten. Dadurch wurden in der Aufstellung **aller** importierten Spiele keine Namen angezeigt. Der Importer schreibt jetzt die korrekten Keys; der idempotente Rake-Task `games:fix_imported_player_names` schlüsselt bereits importierte Spiele (`Game#players`) nachträglich um.
- **Aktuelle-Saison-Teamabgrenzung**: `Team.current_season` filtert jetzt über die `season_id` der Liga (Subquery `League.current_season`) statt über die reine ID-Schwelle `league_id >= current_min_league`. Damit erscheinen Teams aus (frisch importierten) Alt-Saisons mit hohen `league_id` **nicht mehr** fälschlich in der aktuellen Saison (VM/TM-Team-Scoping, Vereins-/Lizenzansichten). Voraussetzung für den Altdaten-Import.
- **Vereins-/Team-Logos – kleine Variante**: Verkleinerte Logos (100×100), die in Tabelle und Spielplan angezeigt werden, wurden für neu hochgeladene Bilder nicht mehr erzeugt. Ursache: ActiveStorage nutzte unter `load_defaults 5.1` den Variant-Processor `:mini_magick`, dessen Gem nicht installiert ist (`LoadError: cannot load such file -- mini_magick`). Der Processor ist jetzt explizit auf `:vips` gesetzt, `ruby-vips` als Gem und `libvips` im Docker-Image ergänzt. (Ältere Logos waren unauffällig, weil ihre Variante bereits früher erzeugt/gecached war.)
- **PR-Review-Nachbesserungen (unveröffentlichte Features)**: Altdaten-Spieleranlage legt namensgleiche Spieler mit identischem Geburtsdatum nicht mehr doppelt an (Abgleich über den Namensindex) und überspringt MariaDB-Nulldaten (`0000-00-00`); `player_attrs` setzt `gender` nur bei explizitem `geschlecht` 0/1 (sonst `nil` statt fälschlich „W"). `PATCH user/mail-preferences` antwortet bei fehlendem Wert mit `422` statt `500`. `RefereeFeedbackMailer#form_available` hat nun auch eine Text-Variante (multipart).
- **Scorerwertung**: `Game#penalty_mapping` brach mit `nil.to_sym` ab, wenn eine Strafe in `Setting.penalties` kein `mapping`-Feld hatte (z. B. Basis-Seeds). Jetzt wird die Strafenwertung für solche Events übersprungen statt die gesamte Liga-Scorerliste fehlschlagen zu lassen.
- **Transfer ohne Spieler-E-Mail – verständlichere Meldung**: Beim Anlegen (`POST admin/transfer_requests`) und bei der Vereinsgenehmigung (`approve_club`) eines Transfers für einen Spieler ohne hinterlegte E-Mail-Adresse lautet die `422`-Meldung jetzt „Für das Spielerprofil ist keine E-Mailadresse hinterlegt. Bitte den aktuellen Verein oder die zuständige SBK kontaktieren." (statt des bisherigen Hinweises, die E-Mail selbst im Spielerprofil einzutragen – was VM-seitig nicht für jeden möglich ist).
- **SBK ohne Zugriff auf Schiedsrichter-Lizenzlisten**: Die Schiedsrichterverwaltung inkl. Lizenzlisten (`menu_item_referee_admin`, `admin/referees`) ist wieder dem Schiedsrichterwesen vorbehalten – Admin und RSK (Ansetzer weiterhin mit eingeschränktem Lesezugriff für die Ansetzung, VM für die eigenen Vereinsschiris). Die SBK (Spielbetrieb) hatte seit dem LV-Schiedsrichterzugriff (#79) Einsicht in die Schiri-Lizenzdaten aller von ihr betreuten Spielbetriebe; dieser Zugriff entfällt nun konsistent in Menüfreigabe (`User#login_hash`), Endpoint-Autorisierung (`authorize_referee_access!`, `can_access_referee?`) und Bestands-Scoping (`RefereeScoping`). Betrifft alle Verbände.

### Neu

- **Schiedsrichter-Ansetzung: Verein statt zwei Schiris**: Eine Ansetzung kann jetzt alternativ an einen **Verein** vergeben werden (der die Schiedsrichter selbst stellt) – entweder/oder: entweder ein Verein **oder** zwei Schiedsrichter (`referee_assignments.club_id`, Modell-Validierung `club_or_referees_exclusive`). Der **Schiedsrichtercoach** ist in beiden Fällen auf Personenebene möglich. Wählbare Vereine sind die des eigenen Landesverbands bzw. der via Freigabe geteilten LV (neuer Endpoint `GET admin/referee_assignments/clubs`, gescopt über die Ansetzer-Berechtigungen des Nutzers; Admins sehen alle). Beim **Veröffentlichen** einer Vereins-Ansetzung wird im öffentlichen Spielplan der **Vereinsname** als Schiedsrichter-Angabe gesetzt; es geht **keine** E-Mail an den Verein (der Coach wird wie gehabt benachrichtigt). Wird eine bereits veröffentlichte Schiri-Ansetzung auf einen Verein umgestellt, werden die zuvor benachrichtigten Schiris über die Änderung informiert.
- **Gültigkeitsdauer je Schiri-Lizenzstufe**: `RefereeLicenseLevel` hat ein Feld `validity_years` (Default 2), im Admin (`admin/referee_license_levels`) pro Stufe einstellbar. Bei der Lizenzvergabe über Kursergebnisse wird `referee.gueltigkeit` automatisch auf den **30.09. (Kursjahr + `validity_years`)** gesetzt (`RefereeLicenseLevel.gueltigkeit_for`); im LV-Review wird die Gültigkeit bei Stufenwahl entsprechend abgeleitet (manueller Wert hat weiterhin Vorrang). Bestehende `gueltigkeit`-Werte bleiben unangetastet (nur Neuvergaben). Beispiel: LJ/L3 = 1 Jahr, L2/L1/N* = 2 Jahre.
- **Schiri-Feedback – Benachrichtigung der Teammanager**: Sobald das Feedback-Fenster für ein gespieltes Spiel öffnet (24 h nach Anpfiff, Liga mit `referee_feedback_enabled`), erhalten die verantwortlichen Teammanager eine E-Mail mit Link zur Feedback-Seite (`/verein/schiri-feedback`) und Hinweis auf die 24-h-Frist. Neuer `RefereeFeedbackMailer#form_available` (admin-pflegbar via EmailTemplateCatalog) + idempotenter Rake-Task `referee_feedback:notify_available` (Cron; `games.referee_feedback_notified_at` verhindert Doppelversand). Respektiert den Info-Mail-Opt-out (`users.receive_info_mails`).
- **Teammanager – Info-Mail-Opt-out**: Neue Spalte `users.receive_info_mails` (Default `true`) und Endpoint `PATCH user/mail-preferences`. Teammanager können den Empfang informeller System-Mails im Profil abschalten; die Einstellung ist **nur für TM** änderbar (Endpoint lehnt Nicht-TM mit `403` ab). `login_hash` liefert `receive_info_mails` und `can_manage_mail_preferences` (= ist TM) fürs Frontend. Versendende Stellen prüfen das Flag vor dem Versand.
- **Lizenz**: Projekt unter der **GNU AGPLv3** veröffentlicht (`LICENSE` ergänzt, Lizenzhinweis im README). Vorbereitung der Open-Source-Veröffentlichung des Repos.
- **Altdaten-Import 2010/11–2013/14 (PoC, intern)**: Grundgerüst zur Rekonstruktion der vier Saisons vor 2014/15 aus den MariaDB-Dumps des Vorgängersystems. Reine Transformationen (`LegacyImport::Transformer`/`Vocab`) bilden `ereignis`→`events`, `mitspieler`→`players` sowie Liga-/Team-/Spieltag-Attribute ab; Rake-Tasks `legacy:league` (MariaDB), `legacy:league_json`, `legacy:bundle` und `legacy:dir` importieren idempotent (Dry-Run als Default, `WRITE=1` schreibt). Der Import läuft saisonweit in zwei Phasen über alle Verbände: erst Ligen/Teams (`team_map` `(verband, id_mannschaft)`), dann Spieltage/Spiele – der effektive Verband eines Teams kommt aus `begegnung.id_verband_team`, sodass auch verbandsübergreifende Wettbewerbe (FD-Pokal, Deutsche Meisterschaften) auflösen. Spieler-Lineups werden via `LegacyImport::PlayerResolver` (Name + Geburtsdatum) auf echte Player-IDs gemappt, Vereine über normalisierte Namen. Verifiziert: voller Probelauf aller 9 Verbände × 4 Saisons (2010/11–2013/14), 10.104 Spiele in eine Dev-DB; Tabellen/Scorer/Ergebnisse rechnen korrekt. Kein produktiver Endpoint – siehe `docs/legacy_import_2010-2014.md`.

### Verbessert
- **Spielberichtseingabe erst am Spieltag startbar**: Der Übergang in den Status „Events eintragen" (`ingame`) über `set_game_status` ist erst **ab dem Spieltag** möglich – ein vorab geöffneter Spielbericht (Status `ingame`) hatte das Spiel u. a. aus der Schiedsrichter-Ansetzungs-Übersicht (`Game.not_started`) verschwinden lassen. Vor dem Spieltag liefert der Endpoint `422` mit klarer Meldung („… kann erst am Spieltag (TT.MM.JJJJ) gestartet werden."); Nacherfassen am Spieltag oder später bleibt möglich, Admins dürfen für Korrekturen übersteuern. Die Spielvorbereitung (`pregame`: Kader/Schiris/Spielsekretariat) ist weiterhin jederzeit vorab möglich.
- **Schiri-Lizenzliste – Saisonspiele**: Die Übersicht `GET admin/referees` liefert je Schiedsrichter jetzt `season_game_count` (Anzahl der Spiele in der aktuellen Saison; gezählt wie bei `Referee#games` über `referee_ids` bzw. die führende Lizenznummer in `referee1/2_string`). Die Zahl wird in **einer** Aggregations-Query über die Saisonspiele ermittelt (keine N+1-Counts über die Liste). Grundlage für die neue Spalte „Saisonspiele" im Frontend.
- **Ladezeit Tabelle/Scorer/Gruppen-Tabelle**: `GET /leagues/:id/table`, `/grouped_table` und `/scorer` werden jetzt 5 min gecacht (`Rails.cache`, analog zum bereits gecachten `schedule`). Diese Endpunkte parsten bisher bei **jedem** Aufruf die JSONB-`events`-Spalte sämtlicher Spiele neu (Ergebnis-/Scorer-Berechnung in Ruby) – bei großen Ligen der teuerste Read. Die Caches (inkl. `schedule`/`current_schedule`) werden zentral über einen `Game`-`after_commit`-Hook (`flush_league_caches`) invalidiert, der bei **jeder** Spieländerung greift – Ergebnis-/Aufstellungseingabe, Statuswechsel, Autofill, Löschung. Das Caching liegt im Controller, der modellinterne `League#grouped_table`-Aufruf der Cup-Befüllung bleibt uncached/frisch.
- **`Setting.current`-Caching**: Die Single-Row-Konfiguration (Saisons, Strafen, Liga-Kategorien …) wird pro Request vielfach gelesen, aber selten geschrieben. `Setting.current` cacht das Objekt jetzt (`settings/current`, 1 h TTL als Sicherheitsnetz) und invalidiert es per `after_commit` bei jeder Setting-Änderung – das spart die wiederholte `Setting.first`-Query über fast alle Requests hinweg. Der `after_commit` leert zusätzlich `settings/init`, sodass eine neu angelegte/gewechselte Saison sofort (statt bis zu 30 min verzögert) erscheint.
- **Schiri-Verfügbarkeiten**: Verfügbarkeiten können jetzt auch für den **heutigen Tag** eingetragen werden (vorher frühestens morgen); die Datums-Validierung lehnt nur noch echte Vergangenheit ab. Der Default-`index` (ohne `date_from`/`date_to`) liefert ab heute statt ab morgen.
- **Schiri-Ansetzung**: Die Endpunkte `admin/referee_assignments/games`, `/available` und `/available_coaches` liefern jetzt Vereins-IDs (`home_team_club_id`/`guest_team_club_id` bzw. `club_id` je Schiri/Coach), damit das Frontend eine **Befangenheits-Warnung** zeigen kann, wenn ein angesetzter Schiri/Coach Mitglied einer der beiden spielenden Vereine ist.
- **Altdaten-Import (PoC, intern)**: Der Import übernimmt jetzt zusätzlich **Betreuer** (`betreuer` → `home_team_coaches`/`guest_team_coaches` im Live-Hash-Format `coachN_string`/`coach1_signed`) und die **Spielbericht-Felder** (`spielbericht` → Schiri-Freitext `referee1/2_string`, Unterschriften, Timeouts `home/guest_timeout_string`, Kommentar `record_comment`, Protest, Verlängerung). Export-SQL-Vorlage, `legacy:league` und der JSON-/Batch-Pfad liefern/verarbeiten beide Tabellen; reine Transformationen mit Unit-Tests. Schiris bleiben bewusst Freitext (keine `referees`-Verknüpfung).
- **Altdaten-Import – Lizenzen (PoC, intern)**: `*_lizenz` + `*_lizenzverlauf` werden zu `players.licenses`-Einträgen (`team_id`, `league_class_id`, `league_category_id`, chronologische `history` mit `license_status_id`/`created_at`) und idempotent pro Spieler (Schlüssel `LIC:<verband>:<saison>:<id_lizenz>`) in die jeweiligen Spieler gemergt (neue Phase 3 der Saison-Transaktion; forward-only wie der übrige Import). Lizenzstatus mappt 1:1 (alt 1–6 == `License::APPROVED..TRANSFER`). Export-SQL/`legacy:league` liefern beide Tabellen mit; `Transformer.license_attrs` ist unit-getestet.
- **Altdaten-Import – Stammdaten-Anlage (PoC, intern)**: Fehlende **Vereine** (`global_verein` → `clubs`) und **Spielorte** (`global_spielort` → `arenas`) werden jetzt beim Import **angelegt**, wenn kein normalisierter Namens-Treffer im Live-Bestand existiert (vorher nur Verknüpfung, sonst verworfen). Idempotent über den Namensindex (frisch angelegte werden registriert → Re-Runs matchen statt duplizieren). Export-SQL/`legacy:league` liefern Vereine/Spielorte als vollständige Datensätze; `Transformer.club_attrs`/`arena_attrs` sind unit-getestet.
- **Altdaten-Import – Spieler-Anlage (PoC, intern)**: Aufstellungs-/Lizenz-Spieler ohne Match im Live-Bestand werden jetzt **angelegt** (`global_spieler` → `players`: Name, Geburtsdatum, Geschlecht 0/1 → `W`/`M`) – konservativ **nur mit Geburtsdatum**, sonst bleibt der Eintrag im Lineup denormalisiert. Idempotent über den Namensindex (Name+Geburtsdatum), sodass dadurch auch mehr Lizenzen (Phase 3) andocken. Schiedsrichter bleiben bewusst Freitext (keine Anlage). `Transformer.player_attrs` ist unit-getestet.
- Ausrichter-Mails zur Schiedsrichter-Ansetzung (`GameDayMailer#published_referees_to_host` bei vollständigem Spieltag sowie `GameDayMailer#updated_referees_to_host` bei nachträglicher Umbesetzung) führen jetzt – sofern hinterlegt – die **E-Mail-Adressen** der angesetzten Schiedsrichter und des Schiedsrichtercoachs in Klammern hinter dem Namen auf, damit der Ausrichter die Beteiligten direkt kontaktieren kann.
### Geändert

- **Schiedsrichter-Verfügbarkeiten statt Sperrtermine**: Die Logik wurde umgedreht. Schiedsrichter*innen hinterlegen unter „Meine Verfügbarkeiten" aktiv die Tage, an denen sie pfeifen können, statt ihre Sperrtermine einzutragen. Ansetzer können nur noch Personen wählen, die für den jeweiligen Tag eine Verfügbarkeit hinterlegt haben (`available`/`available_coaches` liefern ausschließlich Schiris mit Eintrag am Spieltag; ohne Eintrag = nicht wählbar). Die Wochenend-Matrix unterscheidet jetzt `verfügbar` (grün) / `angesetzt` (blau) / `nicht verfügbar` (Standard). Endpunkte umbenannt von `referee/blocked_dates` zu `referee/availabilities` (`GET`/`POST`/`POST …/bulk`/`DELETE …/:id`, Body-Schlüssel `availability` statt `blocked_date`), Tabelle `referee_blocked_dates` → `referee_availabilities`. Bestehende Sperrtermine werden bei der Migration verworfen (leerer Start).

---

## [1.39.0] - 2026-06-23

### Neu
- **Ansetzungslogik je Landesverband schaltbar**: In den Verbandseinstellungen steuert das neue Flag `referee_assignment_enabled` (Standard: aus), ob die Schiedsrichter-Ansetzung für einen Landesverband genutzt wird. Nur wenn aktiv, bietet der Spiel-Editor die Option „Ansetzung durch RSK" (über `additional_references.referee_assignment_enabled`) und die Rolle Ansetzer sieht die Menüpunkte „Ansetzungen" und „Verfügbarkeiten" (`menu_item_referee_assignments`/`menu_item_referee_availability`). National betriebene Spielbetriebe ohne Landesverband (z. B. FD/1. Bundesliga) bleiben unabhängig vom Flag immer aktiv.

---

## [1.38.0] - 2026-06-23

### Neu
- **Schiri-Feedback**: Vereine geben nach dem Spiel eine verpflichtende Rückmeldung zum Schiedsrichtergespann ab (`GET`/`POST /api/v2/user/referee_feedbacks`). Pro Spiel und Mannschaft genau eine Abgabe (TM/VM), frühestens 24 Stunden nach Anpfiff. Liga, Spielnummer, angesetzte Schiedsrichter und die eigene Mannschaft werden automatisch aus dem Spiel vorbelegt; abgefragt werden zwei Bewertungen (Linie/Konstanz und Kommunikation, je 1–10) sowie drei Freitextfelder. Freigeschaltet wird das Feedback je Liga über das neue Flag `referee_feedback_enabled` (z. B. 1. FBL Herren/Damen); der Menüpunkt erscheint nur für TM/VM mit einer Mannschaft in einer solchen Liga. Die abgebende Seite sieht nur den Status (offen/erledigt). Auswertung ausschließlich in der Schiriverwaltung am Schiri-Profil (`GET /api/v2/admin/referees/:id/feedbacks`, Durchschnitte + Einzelrückmeldungen) – sichtbar nur für Admin, FD-RSK und FD-Ansetzer; unsachliche Rückmeldungen lassen sich ausblenden (`PATCH /api/v2/admin/referee_feedbacks/:id`).

---

## [1.37.1] - 2026-06-22

### Behoben
- Schiedsrichter „Meine Spieltage": Ein Spieltag listete bislang **alle** Spiele des Tages auf statt nur jene, auf die der eingeloggte Schiri tatsächlich (veröffentlicht) angesetzt ist. Dadurch erschien z. B. ein früheres Parallelspiel in derselben Halle fälschlich in der eigenen Spielübersicht (`GET /api/v2/referee/game_days`). Die Spiel-Liste je Spieltag ist jetzt auf die eigenen Ansetzungen eingeschränkt.

---

## [1.37.0] - 2026-06-22

### Neu
- Schiedsrichter-Ansetzung: Eine bereits **veröffentlichte** Ansetzung kann nachträglich umbesetzt werden (`PUT …/referee_assignments/:id`). Ändert sich dabei die Besetzung tatsächlich (Schiri-Menge oder Coach – ein reiner Positionstausch Schiri 1 ↔ 2 zählt nicht), wird der öffentliche Spielplan (`nominated_referee_string`) aktualisiert und **eine Update-Mail** an die **alten und neuen** Schiris sowie den Coach (`RefereeMailer#updated_assignment_notification`) und an den **Ausrichter** (`GameDayMailer#updated_referees_to_host`) versendet – beide als E-Mail-Vorlagen pflegbar. Ohne echte Änderung wird nichts versendet; nicht veröffentlichte (vorläufige) Ansetzungen lösen beim Speichern weiterhin keine Mail aus.

---

## [1.36.0] - 2026-06-22

### Behoben
- Schiedsrichter-Scope: Der gemeinsame Verbands-Scope (`RefereeScoping#lv_club_ids`) berücksichtigt jetzt **Vereins-Freigaben** (`StateAssociationRelease`). Gibt ein Landesverband seine Vereine an einen Spielbetrieb frei, gehören deren Schiedsrichter nun zum ansetzbaren/sichtbaren Bestand – konsistent in Ansetzungs-Dropdown, Verfügbarkeits-Matrix und Schiedsrichter-Admin-Liste (bisher nur die Vereine des eigenen LV).
- Ansetzer-Rolle: Die Ansichten **Ansetzungen** und **Verfügbarkeiten** sowie das **Schiedsrichter-Bearbeiten** brachen für reine Ansetzer (ohne RSK) mit „Berechtigungsfehler: Nicht berechtigt" ab, obwohl die Menüpunkte sichtbar waren. Ursache: Die unterstützenden Lese-Endpoints `GET …/settings/seasons`, `GET …/referee_qualification_types` und `GET …/referee_license_levels` (von diesen Seiten beim Laden aufgerufen) ließen die Ansetzer-Rolle nicht zu. Diese Lese-Endpoints erlauben jetzt zusätzlich `ansetzer`.

### Verbessert
- Schiedsrichter-Ansetzung: Die Auswahl-Dropdowns (`GET …/referee_assignments/available`) sind jetzt **verbandsgescopt** (analog zur Verfügbarkeits-Matrix, inkl. Freigaben) statt bundesweit alle Schiedsrichter zu liefern, und geben je Kandidat zusätzlich `kurzfristig_mobil` zurück (Grundlage für den „kurzfristig mobil"-Filter im Frontend). Die Ansetzungs-Liste (`GET …/referee_assignments/games`) liefert je Spiel zusätzlich `national` (Bundesspielbetrieb ohne Landesverband) für die clientseitige Lizenz-Vorauswahl.

---

## [1.35.0] - 2026-06-19

### Verbessert
- Schiedsrichter-Benutzerkonten: Beim Anlegen eines Kontos über den Button im Schiedsrichter-Admin wird nun eine eigene **Begrüßungs-E-Mail** verschickt (Betreff „Dein Schiedsrichteraccount im Saisonmanager"), die den **Benutzernamen** (z. B. `sr-3204`) enthält und zum erstmaligen Setzen des Passworts auffordert – statt der bisherigen „Passwort vergessen"-Mail. Neue, in den E-Mail-Vorlagen pflegbare Vorlage `UserMailer#referee_account_created` (Platzhalter `{{username}}`, `{{link}}`).
- Schiedsrichteransetzungen: Die Ansetzungs-Liste (`GET …/referee_assignments/games`) liefert nun zusätzlich den Ausrichter-Verein (`club`) je Spiel mit (Grundlage für den CSV-Export im Frontend).
- E-Mail-Vorlagen: `GET /api/v2/admin/email_templates` liefert je Vorlage nun zusätzlich `default_body` – den Quelltext des Code-Standard-Views (ERB), der versendet wird, solange kein eigener Body gepflegt ist. Damit kann die Admin-UI auch ohne Anpassung anzeigen, was aktuell tatsächlich verschickt wird.

### Neu
- Neue Benutzerrolle **Ansetzer** (`user_group_id 7`) zur Trennung von Schiedsrichter-Ansetzung und RSK. In Landesverbänden, in denen diese Aufgaben getrennt sind, übernimmt die reine RSK künftig nur noch Schiedsrichterdaten-Verwaltung und Online-Tests, während die Schiedsrichter-Ansetzungen (`referee_assignments`) ausschließlich der Ansetzer-Rolle vorbehalten sind. Der Ansetzer erhält zusätzlich (eingeschränkten) Lesezugriff auf die Schiedsrichterdaten. Wer wie bisher alle drei Aufgaben wahrnimmt, erhält schlicht beide Rollen (RSK + Ansetzer). Ansetzer sind – wie SBK/RSK – LV-gescopt (Bundes-Spielbetrieb → globaler Scope); Anlegen/Zuweisen erfolgt über die Benutzerverwaltung (`POST/PATCH /api/v2/admin/users`).
- Schiedsrichteransetzungen: Sobald für einen Spieltag **alle** Spiele eine veröffentlichte Ansetzung haben, erhält der Ausrichter (`game_day.club.contact_email`) **genau eine** zusammenfassende E-Mail mit allen Spielen und den jeweils angesetzten Schiedsrichtern (`GameDayMailer#published_referees_to_host`, als E-Mail-Vorlage pflegbar). Der Versandzeitpunkt wird in `game_days.host_notified_at` festgehalten, sodass erneutes/nachträgliches Veröffentlichen keine zweite Mail auslöst (#350).
- Schiedsrichterprofil: Optionales Feld **Telefonnummer** (`referees.telefonnummer`). Über `GET/PUT /api/v2/referee/profile` pflegbar; die Nummer wird der RSK in der Ansetzungs-Ansicht (`referee_assignments`) für dringende Fälle angezeigt (#643).
- Schiedsrichterprofil: Optionales Feld **„Ich bin kurzfristig mobil"** (`referees.kurzfristig_mobil`, Default `false`). Der Schiedsrichter kann selbst angeben, ob er kurzfristig (mobil) für Ansetzungen einspringen kann; über `GET/PUT /api/v2/referee/profile` pflegbar. Dient – wie Telefonnummer, Heimadresse und Schiri-Partner – ausschließlich der Ansetzung.
- Schiedsrichteransetzungen: Optionale Ansetzung eines **Schiedsrichtercoachs** je Spiel (`referee_assignments.coach_id`). Als Coach ansetzbar sind Personen mit gültiger Beobachtungs-Zusatzlizenz (Qualifikationstyp `B…`, `valid_until` leer oder in der Zukunft) – diese sind immer auch Schiedsrichter. Neuer Endpoint `GET /api/v2/admin/referee_assignments/available_coaches?date=…` liefert die Coach-Kandidaten ohne Sperrtermin am Spieltag; `coach_id` ist über `POST/PUT …/referee_assignments` pflegbar. Ein angesetzter Coach wird in der Veröffentlichungs-E-Mail an die Schiedsrichter mit aufgeführt (neuer Platzhalter `{{coach_name}}`). Der Coach **selbst erhält ebenfalls eine Ansetzungs-Mail** (`RefereeMailer#published_coach_notification`) mit Spieltag-Details, den Namen der angesetzten Schiris und dem Lizenzlisten-Link; in der zusammenfassenden E-Mail an den Ausrichter (`GameDayMailer#published_referees_to_host`) wird der Coach je Spiel namentlich genannt.
- Schiedsrichter-Verfügbarkeiten: Neuer Endpoint `GET /api/v2/admin/referee_assignments/availability?season_id=…&date_from=…&date_to=…` liefert eine Wochenend-Verfügbarkeitsmatrix („war room") aller aktiven Schiedsrichter des eigenen Verbands – je Schiri und Spielwochenende ein Status `frei` / `gesperrt` (Sperrtermin) / `angesetzt` (bereits eingeteilt), inkl. Lizenzstufe je Schiri (für Filter) und Spielanzahl je Wochenende. Neue Permission `menu_item_referee_availability` für die Ansetzer-Rolle.
- Transfersperrfrist: Nach einem erfolgreich abgeschlossenen Transfer kann für denselben Spieler **4 Wochen lang kein neuer Transferantrag** gestellt werden (`POST /api/v2/admin/transfer_requests`). Maßgeblich ist der tatsächliche Abschlusszeitpunkt des letzten Transfers (`transfers.created_at`), nicht das LV-Genehmigungsdatum – damit greift die Sperre auch bei geplanten Transfers mit Wunschdatum korrekt ab Ausführung. Freigaben (`request_type: release`) lösen die Sperre nicht aus und sind nicht betroffen. Bei aktiver Sperre antwortet der Endpoint mit `422` und nennt das Enddatum der Sperrfrist.
- Benutzerverwaltung: Ein Konto kann nun **mehrere Rollen** gleichzeitig haben (z. B. RSK **und** Ansetzer), damit Personen, die beide Aufgaben wahrnehmen, alle zugehörigen Menüpunkte sehen. Neue Admin-Endpoints `POST /api/v2/admin/users/:id/add_role` und `DELETE …/remove_role` (Rolle inkl. Verbund/Verein hinzufügen bzw. entfernen; Duplikate werden abgewiesen, die letzte Rolle bleibt erhalten). Nur für Admins (Permission `manage_user_roles`); die Admin-Rolle selbst wird hierüber bewusst nicht vergeben.

### Behoben
- Schiedsrichter-Verfügbarkeiten: Die Wochenend-Matrix (`GET …/referee_assignments/availability`) zeigte für (global gescopte) Ansetzer – z. B. Floorball Deutschland – **keine** Schiedsrichter. Ursache: Filterung über `referees.game_operation_id` (häufig leer; Verbandszuordnung läuft v. a. über den Verein). Die Ansicht nutzt jetzt dieselbe Scoping-Logik wie der Schiedsrichter-Admin (`scope_to_permitted_referees`, in den Concern `RefereeScoping` extrahiert) → globale Rolle sieht alle aktiven Schiris, LV-Rollen die ihres Verbands.
- Schiedsrichteransetzungen: Die Liste der ansetzbaren Spiele (`GET /api/v2/admin/referee_assignments/games`) zeigt nun nur noch Spiele, die im Spiel-Editor für die Ansetzung durch die RSK markiert wurden (Sentinel „Ansetzung durch RSK" in `nominated_referee_string`) bzw. für die bereits eine Ansetzung existiert. Zuvor erschienen alle Spiele im Saison-/Zeitraum-Scope unabhängig von der Markierung.
- Schiedsrichteransetzungen: Bereits begonnene oder abgeschlossene Spiele erscheinen nicht mehr in der Ansetzungs-Liste (`GET …/referee_assignments/games`); es werden nur noch nicht angepfiffene Spiele (`game_status` leer/`pregame`) berücksichtigt (#351, 4.2).
- Schiedsrichteransetzungen: Die RSK eines Bundes-Spielbetriebs (z. B. FD) sieht und bearbeitet jetzt ausschließlich Ansetzungen ihres eigenen Spielbetriebs. Zuvor wurde eine Bundes-RSK in `permission_hash` auf „alle Verbände" hochgestuft und sah dadurch auch Spiele fremder Landesverbände. Das Scoping in `referee_assignments` (Liste, Ansetzungs-Liste, Berechtigungsprüfung) leitet die `game_operation_id`(s) nun direkt aus den RSK-Berechtigungen ab (#351, 4.3).

---

## [1.34.0] - 2026-06-16

### Neu
- E-Mail-Vorlagen: zusätzlich zum Betreff ist nun auch der **Body** pro Vorlage pflegbar (`email_templates.body`). Ein gepflegter HTML-Body (mit `{{platzhalter}}`) ersetzt das Code-ERB-View; ist er leer, bleibt unverändert das bisherige View aktiv. Platzhalterwerte werden HTML-escaped, das Admin-HTML wird auf eine Tag-/Attribut-Whitelist sanitisiert. Über `GET/PATCH /api/v2/admin/email_templates` mitpflegbar.

---

## [1.33.0] - 2026-06-16

### Neu
- Optionaler manueller VSK-Workflow: Landesverbände können per Flag „Manuelle Erstellung von Protesten durch die SBK" (`state_associations.manual_proceeding_creation`) einstellen, dass nach Upload eines Berichtsformulars nicht automatisch die VSK benachrichtigt wird, sondern ein **Verfahrensvorschlag** für die SBK entsteht. Neue SBK-Endpoints `GET /api/v2/admin/proceeding_proposals` (offene Vorschläge im eigenen Scope), `GET …/:id`, `POST …/:id/reject` (Vorschlag ablehnen, Unterlagen verwerfen) und `POST …/:id/open` (Verfahren eröffnen → VSK-Mail mit SBK-Reply-To). Permission `menu_item_proceeding_proposal_admin`. Default `false` → bisheriges Automatik-Verhalten unverändert.
- Admin-pflegbare E-Mail-Vorlagen: Betreff, Absender (From) und Reply-To der vom System verschickten E-Mails können pro Mailer-Action über `GET/PATCH /api/v2/admin/email_templates` gepflegt werden (Permission `menu_item_email_template_admin`, nur Admin). Ohne gepflegten Datensatz greifen unverändert die bisherigen Code-Defaults; der Katalog (`EmailTemplateCatalog`) liefert je Vorlage die verfügbaren `{{platzhalter}}` für den Betreff. Das Pflegen des E-Mail-Bodys ist für eine spätere Ausbaustufe vorgesehen (Spalte `email_templates.body` bereits angelegt).
- Konfigurierbare angenommene Spieldauer als Grundlage für Hallenbelegungs- und Schiedsrichter-Konfliktprüfungen. Die Dauer (inkl. Puffer) kann pro Liga gepflegt werden (`leagues.game_duration_minutes`); ohne Pflege greift ein optionaler globaler Default und sonst das bisherige perioden-basierte Verhalten (Großfeld 2 h, sonst 1 h).
- Neuer Endpoint `GET games/scheduling_conflicts`: prüft vor dem Speichern, ob ein (geplantes) Spiel mit anderen Spielen in derselben Halle am selben Tag zeitlich kollidiert. Nicht-blockierend (Speichern bleibt erlaubt, z. B. für Turnierformate mit mehreren Feldern).

### Verbessert
- Das Spiel-Endzeit-/Kalender-Feld (`Game#end_date`, iCal-Export) nutzt nun die effektive Spieldauer statt einer fest verdrahteten Stundenzahl.

---

## [1.32.0] - 2026-06-15

### Neu
- Mehrsprachigkeit des eingeloggten Bereichs: Nutzer*innen können ihre Oberflächensprache (Deutsch/Englisch) selbst wählen. Die Sprache wird am User gespeichert (`users.language`, Default `de`) und im `login_hash` mitgeliefert, sodass sie geräteübergreifend erhalten bleibt. Neuer Self-Service-Endpoint `PATCH user/language`.
- Self-Service „Passwort ändern": Eingeloggte Nutzer*innen können ihr eigenes Passwort über `PUT user/password` ändern (Verifikation des aktuellen Passworts; das neue Passwort muss mindestens 8 Zeichen lang sein).

---

## [1.31.0] - 2026-06-11

### Neu
- Digitaler Schiedsrichterausweis „Mein Ausweis": Schiedsrichter*innen rufen ihren Ausweis direkt im Saisonmanager als mobil optimierte Karte ab – mit Name, Verein, Geburtsdatum, Lizenznummer, Lizenzstufe, Gültigkeit und QR-Code (verweist auf den öffentlichen Lizenzcheck). Ersetzt die bisherige Wallet-Datei-Ausstellung über die Passmeister-API als primären Weg. Der Self-Service-Endpoint `referee/profile` liefert dafür zusätzlich `geburtsdatum`, `verein` und `landesverband`. Der bisherige automatische Versand der Passmeister-Wallet-Datei per E-Mail beim Anlegen eines Schiedsrichters entfällt (der Wallet-Endpoint und die Daten bleiben bestehen).
- Elternzustimmung ist jetzt **pro Liga** über eine Checkbox in der Ligaverwaltung aktivierbar (`parental_consent_required`). Ist sie aktiv, müssen minderjährige Spieler*innen bei der Lizenzbeantragung für diese Liga eine Elternzustimmung hochladen. Die bisherige automatische Ableitung über die Bundesliga-Klassen (`is_buli`) entfällt. (#317)

### Behoben
- Ligaklassen vereinheitlicht: `league_class_id` enthielt drei inkonsistente Wertewelten (Legacy-Zahlencodes wie `10`–`520`, die Settings-Map-Keys `1`–`10` und die neuen Formular-Codes). Eine Daten-Migration normalisiert alle Saisons – Ligen wie Lizenz-Kopien in den Spielerdaten – auf die fünf Codes des Liga-Formulars (`1fbl`/`2fbl`/`rl`/`vl`/`ll`; DM-/Pokal-/Trophy-Wettbewerbe ohne Ligaklasse werden leer) und schlüsselt die `league_classes`-Settings-Map entsprechend um. Damit funktionieren die Erst-/Zweitlizenz-Rangfolge (eine `1fbl`-Liga wurde bisher hinter der Landesliga einsortiert), die Ligaklassen-Anzeige in der Lizenzverwaltung und der Lizenzklassen-Check im Spielbericht (verglich bisher per `to_i` – für die Codes wirkungslos, bei gemischten Alt-/Neu-Werten falsch-positiv) über alle Bestandsdaten. Neue Ligen akzeptieren nur noch die fünf Codes; der ungenutzte Endpoint `GET admin/league_classes` entfällt. (#297)
- Spielbericht: Das Eintragen eines Betreuers (und damit dessen Auswahl bei einer Betreuer-Strafe) schlug mit einem Server-Fehler (500) fehl. Die JSONB-Spalten `home_team_coaches`/`guest_team_coaches` haben den Alt-Default `[]` (Array); der String-Key-Zugriff beim Speichern warf darauf einen `TypeError`. Die Spalten werden nun vor dem Schreiben auf einen Hash normalisiert. Behebt zugleich eine häufige Quelle des generischen „Server-Fehler" bei der Spielberichtseingabe. (#614, #319)

### Verbessert
- Spielbericht: Der fehlende Schiedsrichter (Schiri-Pflicht) wird jetzt bereits beim **Spielstart** geprüft und als Fehler angezeigt – nicht erst beim Abschluss des Spielberichts. (#318)

---

## [1.30.1] - 2026-06-09

### Behoben
- Strafcode-Verwaltung (Schiedsrichterwesen → Einstellungen) warf einen Server-Fehler (500), wenn im Bestand noch alte Strafcode-Einträge im Legacy-Format `{"name"=>…}` ohne `code` lagen: Die Sortierung verglich `nil` mit String. Der Admin-Endpoint ist nun robust gegen solche Alt-Einträge (leerer Code, `name` als Bezeichnung) und stürzt nicht mehr ab. Legacy-Einträge bleiben erhalten (mögliche historische `penalty_code_id`-Referenzen). (#605)

---

## [1.30.0] - 2026-06-09

### Neu
- Strafcode-Verwaltung im Schiedsrichterwesen: Administratoren können Strafcodes (3-stelliger Code + Bezeichnung, z. B. „902 – Stockschlag") anlegen, bearbeiten und (de)aktivieren. Aktive Codes erscheinen im Strafcode-Dropdown der Spielbericht-Eingabe, das bislang mangels gepflegter Codes leer war. Bestehende `penalty_code_id`-Referenzen in Spiel-Ereignissen bleiben stabil (ids werden nie neu vergeben). (#605)

### Verbessert
- Lizenzbegriffe geschärft: Die bisherige „Zweitlizenz" (jede zusätzliche Lizenz neben der Erstlizenz) heißt nun **Zusatzlizenz**. Der Begriff **Zweitlizenz** ist jetzt der Unterart vorbehalten, bei der eine Person zwei Großfeld-Lizenzen hat – dann ist die höhere Liga die Erstlizenz, die niedrigere die Zweitlizenz. Die Lizenz-Globalübersicht liefert dafür ein zusätzliches Feld `is_zweitlizenz`. (#310)
- Ein Spielbericht kann nicht mehr abgeschlossen oder freigegeben werden, solange nicht mindestens Schiedsrichter 1 eingetragen ist. Bislang war die Schiedsrichter-Eingabe kein Pflichtfeld. Schiedsrichter 2 bleibt optional (unterklassige Spiele haben oft nur einen Schiedsrichter). (#604)
- Wallet-Ausweis-Erstellung meldet jetzt zurück, ob eine Benachrichtigungs-E-Mail versendet wurde. Hat der Schiedsrichter keine E-Mail-Adresse hinterlegt, wurde der Pass zwar erstellt, die Mail aber still übersprungen (kein Versand, kein Eintrag im E-Mail-Log). Die Antwort enthält nun `mail_sent`, sodass die Oberfläche „Pass erstellt, aber keine Benachrichtigung versendet (keine E-Mail hinterlegt)" anzeigen kann.

---

## [1.29.7] - 2026-06-08

### Verbessert
- Lizenzgültigkeit („gültig bis") wird jetzt auch in den öffentlichen Lizenzlisten mitgeliefert (Vereins-Lizenzliste pro Spiel und Spielsekretariat). Bisher war das Feld `valid_until` nur im Admin-Lizenzerteilungsbereich verfügbar. (#294)

---

## [1.29.6] - 2026-06-07

### Behoben
- Erst-/Zweitlizenz wurde bei nicht-numerischem `league_class_id` (z.B. `"rl"` für Regionalliga) falsch bestimmt: Die niedrigere Liga wurde fälschlich als Erstlizenz markiert, weil die Rangfolge über `(category+class).to_i` auf konkatenierten IDs lief und an der ersten Nicht-Ziffer abbrach. Die Ligastufe wird jetzt über eine zentrale, robuste Methode `League.class_rank` bestimmt (numerisch nach Zahlenwert, `"rl"` an Regionalliga-Position, Unbekannte ans Ende); bei gleicher Ligastufe entscheidet der frühere Genehmigungszeitpunkt (`License.approval_time`). Das fünffach duplizierte Muster (inkl. Copy-Paste-Fehler in `Player#main_license_hash`) ist entfernt. (#291)
- Kostenfreies Zurückziehen eines Lizenzantrags: Karenzzeit war fälschlich auf 24 Stunden statt 60 Minuten kodiert. Dadurch blieb das kostenfreie Zurückziehen viel zu lange möglich und die Anzeige „kostenfrei bis HH:MM Uhr" wirkte wie die aktuelle Uhrzeit. Die Karenzzeit ist jetzt zentral als `License::GRACE_PERIOD = 1.hour` definiert und an beiden Stellen (Anzeige + Löschlogik) genutzt (#290).

---

## [1.29.5] - 2026-06-06

### Verbessert
- Dockerfile-Basis-Image von `ruby:3.1` auf `ruby:3.2.4` angehoben — passend zu `.ruby-version` und der CI-Ruby-Version (3.2.4). Image-Build + Boot auf 3.2.4 verifiziert.
- PostgreSQL-16-Vorbereitung: CI-Service-Postgres auf 16 angehoben, `pg`-Gem von `~> 1.4` auf `~> 1.5`. Volle Test-Suite gegen pg16 grün; Dump/Restore-Migration 12→16 lokal verifiziert (siehe Issue #275). Die produktive Daten-Migration erfolgt separat im Wartungsfenster.

---

## [1.29.4] - 2026-06-06

### Behoben
- Entwicklungsumgebung: `listen` von `< 3.2` auf `~> 3.8` angehoben. Unter Rails 7.1 verlangen `spring-watcher-listen` und der Dev-File-Watcher `listen ~> 3.5`, wodurch `rails server` lokal mit `Gem::LoadError` abbrach. Nur Dev-Group (`group :development`) — kein Produktions- oder Testeinfluss.

---

## [1.29.3] - 2026-06-06

### Behoben
- `puma` von `~> 5.6` auf `~> 6.4` angehoben. Rails 7.1 nutzt Rack 3 / rackup; puma 5.6 registriert sich nicht beim neuen Server-Handler, sodass `rails server` in Produktion mit „Could not find a server gem" abbrach (Boot-Loop, 502). In Tests fiel das nicht auf, da dort kein Puma-Server gestartet wird.

---

## [1.29.2] - 2026-06-06

### Verbessert
- Rails 7.0 → 7.1 und paper_trail 13 → 15 aktualisiert (Rails 7.0 ist seit März 2025 EOL). `config.load_defaults` bleibt bewusst auf 5.1, damit bestehende `cookies.signed[:user_id]`-Sessions gültig bleiben.

### Behoben
- Test-Umgebung: ActiveJob-Queue-Adapter auf `:test` gesetzt. Der bisherige Default `:async` führte `deliver_later`-Mailer-Jobs (u. a. Transfer-Abschluss) in einem Hintergrund-Thread aus, der sich unter Rails' transaktionalen Tests die DB-Connection mit dem Test-Thread teilte und sie unter PostgreSQL 15 sporadisch desynchronisierte — sichtbar als „message type … arrived from server while idle", nil-Reads und Hänger.

---

## [1.29.1] - 2026-06-06

### Behoben
- `League#set_defaults` entfernt: Der `before_create`-Callback war wegen eines Ruby-Scope-Fehlers (`season_id = …` legte eine lokale Variable an) ein No-op und konnte das Defaulting nie ausführen — `season_id` ist ohnehin `presence`-validiert. Sein einziger Effekt war ein überflüssiger `Setting.first`-Zugriff bei jeder Liga-Erzeugung, der unter Last sporadisch `TransferConsistencyTest` zum Absturz brachte (`undefined method 'systems' for nil`).

---

## [1.29.0] - 2026-06-05

### Neu
- API-Rate-Limiting: Pro API-Key konfigurierbares Request-Limit (Requests/Minute); Keys ohne Limit sind unbegrenzt
- API-Live-Delay: Keys ohne Echtzeit-Flag erhalten Spielereignisse mit 10 Minuten Verzögerung (USP-Schutz für Liveticker); `schedule`/`current_schedule`-Feeds blenden Scores laufender Spiele aus
- API-Key-Verwaltung: Neue Felder `rate_limit` (Integer) und `realtime` (Boolean) über Admin-UI einstellbar
- Tests Phase 3: 25 Invarianten-Tests in `test/invariants/` (Saisonwechsel, Lizenz-, Transfer- und Permission-Konsistenz)
- `rake data_health:check_all` – 6 read-only Konsistenz-Checks für Produktion (exit 1 bei Funden, `FORMAT=json` für Monitoring)
- `Player#append_license_history` – einheitlicher Helper für License-History-Mutationen (garantiert Pflichtfelder)
- SimpleCov: Coverage-Bericht in CI-Artifacts
- `docs/data-model.md`: State-Machine-Diagramme (TransferRequest, Lizenz), Permission-Tabelle, JSONB-Schemas

---

## [1.28.1] - 2026-06-05

### Behoben
- Schiedsrichter: Benutzerkonto wird beim Löschen einer Schiedsrichter-Lizenz automatisch mitgelöscht (saisonmanager-api#234)
- Liga-Qualifikationsregeln: Verband-Scope-Prüfung im Controller korrigiert – ein auf einen Spielverband eingeschränkter Admin konnte bislang Regeln für Ligen anderer Spielverbände bearbeiten (saisonmanager-api#145)
- Liga-Qualifikationsregeln: `grouped_table`-Endpunkt übergibt jetzt wie der `table`-Endpunkt Qualifikationstyp und -label an jede Tabellenzeile (saisonmanager-api#145)

---

## [1.28.0] - 2026-06-04

### Behoben
- Lizenzübersicht: Ausweiskopie wird nicht mehr für alle Ligen pauschal angezeigt. `id_copy` wird jetzt wie jedes andere Pflichtdokument behandelt: nur wenn es in `required_documents` der Liga eingetragen ist, erscheint das Dokument in der Übersicht

### Neu
- Transfer: SBK kann einen Spieler direkt einem anderen Verein zuweisen (`POST admin/transfer_requests/direct_assign`), ohne den mehrstufigen Genehmigungsprozess. Die Direktzuweisung erzeugt einen sofort vollzogenen Transfer (`direct: true`) und erscheint in der Transferliste (für die Abrechnung). Erlaubt nur innerhalb des eigenen Landesverbands; SBK FD (global) und Admin auch verbandsübergreifend. Zusätzlich kann SBK laufende Transfers annullieren (`PATCH admin/transfer_requests/:id/cancel`) (saisonmanager-api#244)
- Merge-Protokoll (Grundlage): Zusammenlegungen werden jetzt in der neuen Tabelle `merge_logs` (`MergeLog`) festgehalten — mit Objekttyp, Ziel-/Quell-ID und -Bezeichnung sowie ausführendem Benutzer. Spieler- und Schiedsrichter-Merge protokollieren ab sofort; die Auswertungs-Ansicht (SBK FD, letzte 6 Monate) folgt separat (saisonmanager-api#249)
- Spielorte: Doppelt angelegte Spielorte können zusammengelegt werden (`POST admin/arenas/:id/merge`). Alle Spieltage des Quell-Spielorts werden auf den verbleibenden Spielort umgehängt, der doppelte Eintrag wird danach gelöscht (saisonmanager-api#247)
- Liga-Altersvoraussetzung: Der in der Liga hinterlegte Stichtag (`deadline`) wird jetzt beim Lizenzantrag ausgewertet. Spieler:innen, die die Altersvoraussetzung nicht erfüllen, können keine Lizenz für die Liga beantragen (`request_license` lehnt mit klarer Meldung ab). `before_deadline` bestimmt die Richtung: `true` = „geboren bis", `false` = „geboren ab". Ohne gesetzten Stichtag gibt es keine Einschränkung; bei fehlendem Geburtsdatum wird nicht blockiert. `before_deadline` wurde dafür von `date` auf `boolean` migriert (saisonmanager-api#248)
- Transfer: Offene Transferanträge, die nicht innerhalb von 14 Tagen abgeschlossen werden (Genehmigungen unvollständig), werden automatisch annulliert (neuer Status `expired`). Umsetzung über den täglichen Rake-Task `transfers:expire` (per Cron); bereits vollständig genehmigte, auf das Wirksamkeitsdatum wartende Anträge (`scheduled`) sind ausgenommen. Keine Erinnerungsmail vor Fristablauf (saisonmanager-api#243)
- Spieltag-Bestätigung für Gastmannschaften: Team- und Vereinsmanager bestätigen über das neue Portal „Meine Spieltage" die Spieltagscheckliste auch für ihre Gastmannschaften (Teams, die nicht zum Ausrichterverein gehören). Jede Gastmannschaft bestätigt eigenständig „ordnungsgemäß" oder meldet „nicht ordnungsgemäß" mit Ja/Nein-Checkliste; bei einer Meldung wird die zuständige SBK per E-Mail informiert (`GameDayMailer#team_checklist_veto`). Gab es an einem Spieltag mehrere Gastmannschaften, muss jede einzeln bestätigen; ohne Bestätigung innerhalb von 48 Stunden gilt sie automatisch als erteilt. Neue Endpunkte `GET user/team_game_days` und `POST user/team_game_days/:game_day_id/teams/:team_id/confirm`
- Schiedsrichter: Sperrtermine können jetzt für beliebige Tage (nicht nur Wochenenden) gesetzt werden; neuer Bulk-Create-Endpunkt für Bereichsauswahl im Kalender (`POST referee/blocked_dates/bulk`)
- Schiedsrichter: Neuer Bereich „Meine Historie" — gepfiffene Spiele aller Saisons (`GET referee/history/games`) und Prüfungsergebnisse vergangener Onlineprüfungen (`GET referee/history/tests`)
- Schiedsrichterverwaltung: Benutzerkonto-Status (`user_id`, `user_name`) im Referee-JSON; neuer Endpunkt `POST admin/referees/:id/create_user` legt automatisch ein verknüpftes Schiri-Konto an
- Schiedsrichterverwaltung: Das verknüpfte Benutzerkonto eines Schiedsrichters kann jetzt direkt aus der Bearbeiten-Ansicht gelöscht werden (`DELETE admin/referees/:id/destroy_user`, Admin-only). Neues Permission-Flag `referee_can_delete_user` steuert die Sichtbarkeit des Buttons (saisonmanager#547)
- Schiedsrichter: Spieltag-Bestätigung im Portal „Meine Spieltage" greift jetzt die Spieltagscheckliste auf. Eine Bestätigung ist nur nötig, wenn der Landesverband der Liga mindestens eine Checklisten-Frage hinterlegt hat. Schiris können den Spieltag als „ordnungsgemäß durchgeführt" bestätigen oder als „nicht ordnungsgemäß" melden und die Checkliste mit Ja/Nein beantworten; bei einer Meldung wird die zuständige SBK per E-Mail informiert (`GameDayMailer#referee_checklist_veto`). Das Referee-JSON liefert `checklist_required`, `checklist_items`, `properly_conducted` und `my_checklist_answers`

### Verbessert
- Lizenzverwaltung: Der Liga-Lizenz-Endpunkt (`admin/leagues/:id/licenses`) liefert zu jedem Spieler nun auch Direktlinks (`id_copy_url`, `parental_consent_url`) zu den hochgeladenen Dokumenten, damit die Liga-Detailseite die Dokument-Icons klickbar anzeigen kann (saisonmanager#552)
- Login: Nach dem Logout wird jetzt zur Login-Seite weitergeleitet statt zur Startseite (saisonmanager#554)
- Vereins-/Verbandsverwaltung: Der nutzersichtbare Begriff „Sportverbund" wurde zu „Spielverbund" vereinheitlicht (saisonmanager#555)
- Schiedsrichter: Spieltag-Bewertung (Bestätigung „ordnungsgemäß" wie auch Meldung „nicht ordnungsgemäß") ist erst ab Beginn des letzten Spiels eines Spieltags möglich; vorher wird sie abgelehnt. Das Referee-JSON liefert dafür `confirmable_from`
- Spielbericht-Checkliste: Die Bestätigungs-E-Mail wird jetzt getrennt versandt — der Ausrichterverein erhält weiterhin die E-Mail mit Token-Einspruchslink, Schiedsrichter:innen erhalten stattdessen eine eigene E-Mail mit Link zum Portal „Meine Spieltage" (kein Token). Die Schiri-Mail wird nur ausgelöst, wenn der LV der Liga eine Checkliste hinterlegt hat

### Behoben
- Platzierungsspiele (saisonmanager#515): Einmal-Korrektur-Task `games:clear_premature_placement_teams`, der bereits verfrüht befüllte Platzierungs-/K.-o.-Spiele (vor dem `autofill_teams!`-Fix gesetzte Teams) wieder auf den Platzhalter zurücksetzt. Exakte Umkehrung des Auffüll-Guards; standardmäßig nur Report, schreibt erst mit `APPLY=1`
- Ligaverwaltung: Landesverbands-Logos wurden nicht mehr angezeigt, wenn der Verband kein Logo als Datei hochgeladen, aber ein Logo in der `logo_url`-Textspalte hinterlegt hat. `GameOperation#meta_hash` fällt jetzt wieder auf die Textspalte zurück (angehängtes Logo behält Vorrang) (saisonmanager#551)
- Transfer: Beim Initiieren eines Transferantrags für einen Spieler ohne hinterlegte E-Mail-Adresse erscheint jetzt sofort eine klare Fehlermeldung mit Hinweis auf das Spielerprofil, statt den Antrag zu starten, der später nicht bestätigt werden könnte (saisonmanager-api#245)
- Schiedsrichter-Kursergebnisse: Der Menüpunkt „Freigabe" (`menu_item_referee_course_review`) wurde Landesverbands-RSK auch dann angezeigt, wenn der Kontrollprozess (`referee_license_review_enabled`) für ihren LV deaktiviert war. Er erscheint jetzt nur noch, wenn mindestens einer der zugeordneten Landesverbände den Prozess aktiviert hat (Admin/globaler FD-RSK weiterhin immer)
- Schiedsrichter: „Meine Spieltage" warf einen Server-Fehler (500), weil die Abfrage `SELECT DISTINCT` mit `ORDER BY game_days.date` kombinierte (in Postgres unzulässig, wenn die Sortierspalte nicht in der Select-Liste steht). Die Filterung über den Assignment-Join wird jetzt von der Präsentations-Query getrennt
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
