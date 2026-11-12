# Entwicklungsprozess

Wie eine Änderung vom Issue in die Produktion kommt. Gilt für die drei Repositories
`saisonmanager-api`, `saisonmanager` (Frontend) und `saisonmanager-docker`. Abgestimmt in
#881; offene Punkte stehen am Ende.

## Umgebungen und Branches

| Umgebung | Adresse | Branch | Datenbank |
|---|---|---|---|
| Produktion | saisonmanager.de | `main` | Produktionsdaten |
| Staging | saisonmanager.dev | `staging` | Kopie der Produktion, per Skript erneuert |

Staging ist durch eine eigene Basic-Auth geschützt und versendet keine Mails an echte
Empfänger (Mailpit). Weil dort echte Daten liegen, gelten für Staging dieselben
Datenschutzregeln wie für die Produktion.

## Ablauf

✋ = wartet auf Freigabe

1. **Issue einstufen.** Betrifft die Änderung die Datenbank (Migration, Datenkorrektur)
   oder Rechte (Rollen, Berechtigungen, Sichtbarkeit)? Die Issue-Vorlagen fragen beides ab.
   ✋
2. **Umsetzungsplan** bei größeren Änderungen: betroffene Stellen, Migration mit Rückweg,
   offene Entscheidungen. ✋
3. **Feature-Branch von `origin/main`**, nicht von `staging`. Derselbe Branch wird später
   der PR gegen `main`; von `staging` abgezweigt nähme er dessen ganzen Rückstand mit.
4. **Umsetzung mit Tests und CHANGELOG-Eintrag** (nur API, siehe unten). Lokal laufen alle
   Tests und RuboCop bzw. ESLint.
5. **Pull Request gegen `staging`.** Die CI läuft auch dort. Review durch Daniel oder
   Martin; das Ergebnis steht als Kommentar am PR („Review durch …“). ✋
6. **Merge nach `staging`** als echter Merge-Commit, Branch nicht löschen. Merge heißt nicht
   Deploy: Deploys werden gebündelt und ausdrücklich angestoßen. ✋
7. **Deploy auf saisonmanager.dev und testen.** Bei Datenbank- oder Rechteänderungen ist
   der Test durch Fachanwender Pflicht (SBK, Vereine, je nach Thema), mit einer
   Testanleitung: welche Rolle, was prüfen, was ist das erwartete Ergebnis. ✋
8. **PR desselben Branches gegen `main`**, Squash-Merge. Danach `main` zurück nach
   `staging` mergen.
9. **Release:** eigener PR `chore: Release x.y.z` mit Versionssprung und CHANGELOG-Block.
   Der Workflow `release.yml` legt daraus das GitHub-Release an.
10. **Deploy Produktion:** erst API (mit Migration), dann Frontend. `deploy.sh` legt vor
    der Migration automatisch einen Datenbank-Dump an. Danach Sichtprüfung. ✋
11. **Abschluss:** Issue schließen. GitHub schließt Issues nur mit `fixes`/`closes`, nicht
    mit „Behebt #NN“.

**Alles geht zuerst über `staging`**, auch Änderungen ohne Datenbank- oder Rechtebezug
(seit 26.10.2026). Nichts landet auf `main`, das nicht vorher auf `staging` war. Die
Pflicht zum fachlichen Test auf Staging gilt nur für Datenbank- und Rechteänderungen.

**Ausnahme `saisonmanager-docker`:** Beide Deploy-Skripte ziehen `main`. Änderungen dort
gehen per PR direkt nach `main` und wirken beim nächsten Deploy auf beiden Umgebungen.

## Versionierung und CHANGELOG

Semantic Versioning, Version in `config/initializers/version.rb`, öffentlich unter
`GET /api/v2/version`.

- **Patch:** Fehlerbehebungen ohne neue Funktion.
- **Minor:** neue Funktionen für Nutzer.
- **Major:** inkompatible Änderungen der API.

Jeder API-PR trägt einen Eintrag unter `## [Unreleased]` in `CHANGELOG.md` mit den
Abschnitten `### Behoben`, `### Neu`, `### Verbessert`. Das Frontend führt kein eigenes
CHANGELOG. Bei Konflikten im CHANGELOG die beiden Stände einzeln zusammenführen
(`git show :2:CHANGELOG.md` / `:3:`), nicht aus den Konfliktmarkern.

## Branchschutz

`main` ist geschützt (CI muss grün sein, eine Freigabe). Es gibt nur einen festen
Entwickler, eine zweite Freigabe kommt deshalb in der Regel nicht zustande; gemergt wird
mit Admin-Rechten. `enforce_admins` bleibt aus diesem Grund aus. Die Freigabe ersetzt
der Review-Kommentar am PR.

## Sicherungen

- **Hetzner-Backup** des ganzen Servers, täglich. Eine Wiederherstellung setzt alles
  zurück.
- **Datenbank-Dump vor jedem Prod-Deploy** (`deploy.sh`, die letzten 10).
- **Täglicher Datenbank-Dump** per Cronjob (die letzten 14).

Beschrieben in der README von `saisonmanager-docker` (Abschnitt Datenbanksicherung),
dort auch das Zurückspielen.

## Datenkorrekturen auf der Produktion

1. Skript schreiben und prüfen, zuerst als Probelauf (`DRY_RUN=1`).
2. Bei Datenbank- oder Rechtebezug zuerst auf Staging laufen lassen.
3. Ausdrückliche Freigabe, dann Live-Lauf.
4. Vor Löschungen eine Sicherung.
5. Skript danach vom Server entfernen und das Vorgehen im Issue dokumentieren.

## Sicherheit

- Die Repositories sind öffentlich. Zugangsdaten, Schlüssel und Passwörter gehören nie
  ins Repository, auch nicht als Standardwert für die Produktion. Auf dem Server stehen
  sie in der nicht versionierten `.env` von `saisonmanager-docker`.
- Ports in den Compose-Dateien nur an `127.0.0.1` binden. Docker umgeht mit
  veröffentlichten Ports die Firewall des Servers.
- Tokens in Links (Passwort, Bestätigungen, Einladungen) nur als Digest speichern und
  befristen.
- Sicherheitslücken nicht als öffentliches Issue melden, siehe `SECURITY.md`.

## Offene Punkte aus #881

1. Staging-Pflicht technisch absichern oder bei der Absprache bleiben?
2. Ablage der Datenbanksicherung außerhalb des Servers (Hetzner Storage Box o. ä.) und
   Aufbewahrungsdauer.
3. Wer gibt PRs frei, wenn Daniel nicht verfügbar ist?
4. Wo halten Tester auf Staging ihre Ergebnisse fest?
5. Zugänge für externe Tester auf Staging: wer vergibt sie?
