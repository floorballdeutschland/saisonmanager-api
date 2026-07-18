# Altdaten-Import 2010/11–2013/14 (PoC)

Rekonstruktion der vier Saisons **2010/11, 2011/12, 2012/13, 2013/14** aus den
MariaDB-Dumps des Vorgängersystems in das aktuelle Rails-Modell. 2009/10 ist im
Altsystem zwar als Saison gelistet, enthält aber keine Daten.

## Altsystem in Kürze

- MariaDB, Tabellen pro **Verband × Saison** mit Präfix: `fvd_2013_2014_begegnung`,
  `fvbb_2012_2013_liga`, … plus globale `global_*`-Stammtabellen.
- Verbände: `fvd, fvn, fvbb, fvbw, flvsh, sbkost, fvh, fvb, nwuv`.
- Pro Saison ~2.400–2.700 Spiele mit vollständigen Tor-/Strafereignissen,
  Aufstellungen und Lizenzen.

**IDs sind nur innerhalb (Verband, Saison) eindeutig** → jede Entität braucht beim
Import einen Remap auf globale IDs. Spieler/Vereine/Schiris/Spielorte sind im
Altsystem bereits global und werden einmalig dedupliziert.

## Schlüssel-Mappings

### Saison (1:1)
Alt `global_saison.id_saison` == neue `season_id` (15 = 2023/24 ⇒ rückwärts
5 = 2013/14 … 1 = 2009/10). Kein Offset.

### Events (ereignis → games.events JSONB)
Tore-Spalten sind **kumulativ**; das Team eines Tores wird über den Sprung im
Spielstand bestimmt. Internes Format laut `fix_imported_game_format.rake`.

| alt `ereignis` | event-key |
|---|---|
| `zeile` | (Sortierschlüssel) |
| `periode` / `zeit` | `period` / `time` |
| `tore_team1` / `tore_team2` | `home_goals` / `guest_goals` (kumulativ) |
| `nr_team1` / `nr_team2` | `home_number` / `guest_number` (Trikotnr) |
| `ass_team1` / `ass_team2` | `home_assist` / `guest_assist` |
| `id_strafe` | `penalty_id` (1→1, 2→3, 3→4, M I/II/III→7/8/9) |
| `id_strafcode` | `penalty_code_id` |

### Aufstellung (mitspieler → games.players JSONB)
`team` (1/2) → `home`/`guest`; `id_spieler` → `player_id` (Remap; 0 = Gastspieler,
Name/Vorname bleiben denormalisiert); `trikotnr`, `torwart`, `kapitain`.

### Liga (liga → leagues)
`id_klasse` → `league_class_id` (10→`1fbl`, 20→`2fbl`, 30→`rl`, 40→`vl`, 50→`ll`;
Jugend/Damen → `age_group`/`female`). `id_kategorie` wird **1:1** als
`league_category_id` übernommen (altes Klein-Int-Schema: 1=GF, 2=KF, 3/4=Pokal,
5=Mixed, 100–102=DM) – `League#forfait_goals`/`#period_count_normal_game`/
`#league_type` branchen für `legacy_league` genau darauf; der Bestand der
Alt-Saisons 6–16 nutzt dieselben Werte. `id_spielsystem` → Punkte-/Tabellenmodus
(nicht `league_system_id`). Alle Altspiele: `legacy = true`.

Vollständige Feld-für-Feld-Tabellen, globale Stammdaten (Vereine/Spieler/Schiris/
Spielorte), Reihenfolge und Risiken: siehe `produktivdaten/MAPPING_KONZEPT_altdaten_2010-2014.md`
(Arbeitsdaten-Repo).

## PoC

| Datei | Zweck |
|---|---|
| `app/services/legacy_import/vocab.rb` | Kuratierte Vokabular-Mappings (Klasse, Kategorie, Strafe, Saison, Lizenzstatus) |
| `app/services/legacy_import/transformer.rb` | Reine Transformationen (Zeilen-Hashes → neue Attribute / JSONB) – ohne DB; inkl. `build_coaches` (`betreuer`→Coaches-Hash) und `spielbericht_attrs` (Schiri-Freitext/Timeouts/Kommentar/Protest/Verlängerung/Unterschriften) |
| `app/services/legacy_import/player_resolver.rb` | Alte `id_spieler` → echte `players`-ID per (Nachname, Vorname, Geburtsdatum) |
| `lib/tasks/import_old_seasons.rake` | Tasks `legacy:prepare` (Preflight) / `legacy:league` (MariaDB) / `legacy:league_json` / `legacy:bundle` (ein Verband-Saison) / `legacy:dir` (alle Bundles); Dry-Run (Default) / `WRITE=1` |
| `lib/tasks/legacy_import/export_all.sql.tmpl` | SQL-Vorlage (`__PFX__`-Platzhalter) – exportiert alle Ligen eines `<verband>_<saison>` als JSON_OBJECT |
| `lib/tasks/legacy_import/export_bundle.sh` | Helper: rendert die Vorlage, schreibt `<pfx>_bundle.json` nach `tmp/legacy/` (nutzt `mysql --raw`, sonst zerbricht Batch-Escaping das JSON) |
| `test/services/legacy_import/*_test.rb` | Minitests: Transformer (Begegnung 488, 3:5) + PlayerResolver |

**Idempotenz:** Alle Datensätze tragen eine herkunftsstabile `legacy_ref`
(`L:<verband>:<saison>:<id_liga>`, analog `T:`/`GD:`/`G:`) mit partiellem
Unique-Index. Der Upsert keyt darauf → Re-Runs aktualisieren denselben Datensatz
(verifiziert: zweiter Lauf = identische Counts).

### Ausführen – zwei Datenquellen

**A) JSON-Bundle (empfohlen für den PoC – kein Gem, keine Dockerfile-Änderung).**
Bundle aus einer MariaDB mit dem geladenen Alt-Dump erzeugen (eine `SELECT
JSON_OBJECT(...)`-Abfrage je Liga, siehe `produktivdaten`-Arbeitsdaten), dann:

```bash
# Dry-Run
bundle exec rails "legacy:league_json" BUNDLE=/app/tmp/legacy/liga33_bundle.json
# Schreiben (idempotent), Liga der GameOperation 1 zuordnen
bundle exec rails "legacy:league_json" BUNDLE=/app/tmp/legacy/liga33_bundle.json WRITE=1 GO_ID=1
```

**B) Direkt aus MariaDB** (benötigt das Gem `mysql2`):

```bash
export LEGACY_MYSQL_URL="mysql2://root:pw@127.0.0.1:3307/saison201314"
bundle exec rails "legacy:league" VERBAND=fvd SEASON=2013_2014 LIGA=33            # Dry-Run
bundle exec rails "legacy:league" VERBAND=fvd SEASON=2013_2014 LIGA=33 WRITE=1 GO_ID=1
```

Der Dry-Run gibt die `league_attrs`, Zähler (Teams/Spieltage/Spiele) sowie für ein
Beispielspiel den berechneten Endstand und die ersten Events aus und meldet
ungemappte Klassen/Feldgrößen.

> Das Gem `mysql2` ist (noch) nicht im `Gemfile` – Variante A umgeht das.

### Batch: ganze Saisons (`legacy:bundle` / `legacy:dir`)

Der Import läuft **saisonweit in zwei Phasen** über alle Verbände einer Saison
(eine Transaktion je Saison):

1. **Ligen + Teams** – `team_map` mit Schlüssel `(verband, id_mannschaft)`.
2. **Spieltage + Spiele** – Heim/Gast aus der Map; der effektive Verband eines
   Teams kommt aus `begegnung.id_verband_team1/2` (sonst eigener Verband). So
   lösen ligaübergreifende **und verbandsübergreifende** Wettbewerbe (FD-Pokal,
   Deutsche Meisterschaften) ihre Teams korrekt auf.

Spieler-Lineups werden über `LegacyImport::PlayerResolver` (Nachname + Vorname +
Geburtsdatum) auf echte `players`-IDs gemappt; Vereine/Spielorte über
normalisierte Namen (`name`/`short_name`/`long_name`).

```bash
bundle exec rails "legacy:bundle" BUNDLE=/app/tmp/legacy/fvd_2013_2014_bundle.json WRITE=1
bundle exec rails "legacy:dir"    DIR=/app/tmp/legacy WRITE=1   # alle Bundles, nach Saison gruppiert
```

Die GameOperation wird aus dem Verband-Präfix abgeleitet (`VERBAND_GO`,
alt-Verband-ID == neue GO-ID), per `GO_ID=` überschreibbar. Nicht auflösbare
Spiele werden gezählt und gemeldet, nicht still verworfen.

### Verifiziert (lokal, Dev-DB)

Pilotlauf **FVD 2013/14, Liga 33 „1. FBL Herren"** (10 Teams, 90 Spiele, 1514
Events) über die JSON-Brücke gegen die prod-nahe Dev-DB:

- Saison-Mapping bestätigt: alt `id_saison 5` == `Setting.seasons["5"]` = `2013/2014`;
  season_id 5 war zuvor leer (echte Lücke, keine Kollision).
- `Game#result_string` des Beispielspiels (BA Tempelhof – MFBC Leipzig) = **`4:7`**,
  exakt der kumulative Roh-Endstand aus dem Dump; Perioden-Split H=[1,1,2,0]/G=[3,2,2,0].
- `League#table` rechnet die vollständige Abschlusstabelle (S/U/N, Tore, Punkte);
  Meister UHC Weissenfels (32 Pkt). → Ergebnis-/Punktlogik greift auf den
  rekonstruierten Daten.
- Voller Verbands-Batch **FVD 2013/14**: 21 Ligen, 33 Teams, 350 Spiele
  geschrieben; reguläre Ligen + innerverbandliche Play-offs/Relegation
  vollständig, Tabellen plausibel (z. B. 2. FBL Nord/West: SSF Dragons Bonn 30 Pkt).
- **Voller Import aller 9 Verbände × 4 Saisons (2010/11–2013/14)**: 448 Ligen,
  1790 Teams, **10.104 Spiele** in die lokale Dev-DB (Saison-IDs 2–5). Tabellen
  rechnen je Saison korrekt (z. B. FVD 2010/11 1. Liga: UHC Weißenfels 34 Pkt).
- **Verbandsübergreifend**: Deutsche Meisterschaften (Herren/Damen/U13–U19) und
  FD-Pokal lösen ihre Teams aus den Landesverbänden auf (z. B. DM Herren 2013/14
  vollständig 18 Spiele).
- **Spieler-Remap**: 78–98 % der Lineup-Spieler je Verband auf echte Player-IDs
  gematcht; Scorerlisten zeigen die korrekten Personen (Liga 33 Topscorer jetzt
  Herren statt zuvor falscher Identitäten).
- **Vereins-Dedup**: Teams werden über normalisierte Namen mit bestehenden Clubs
  verknüpft (z. B. FVD 2013/14: 25/33 Teams mit `club_id`).

### Erledigte Follow-ups

1. ✅ **Verbandsübergreifende Wettbewerbe** – `id_verband_team1/2` + saisonweite
   `team_map` `(verband, id_mannschaft)`.
2. ✅ **Spieler-Remap** – `LegacyImport::PlayerResolver` (Name + Geburtsdatum).
3. ✅ **Stammdaten-Dedup** Vereine/Spielorte (normalisierter Namensabgleich).
4. ✅ **Betreuer + Spielbericht** – `betreuer` → `home_team_coaches`/`guest_team_coaches`
   (Live-Hash `coachN_string`/`coach1_signed`); `spielbericht` → `referee1/2_string`,
   Unterschriften, `home/guest_timeout_string`, `record_comment`, `protest`, `overtime`.
   Export-SQL, `legacy:league` und der JSON-Pfad liefern beide Tabellen mit.
5. ✅ **Lizenzen** – `*_lizenz` + `*_lizenzverlauf` → `players.licenses` (`team_id`,
   `league_class_id`, `league_category_id`, chronologische `history`). Idempotenter
   Merge in den Spieler über `id = LIC:<verband>:<saison>:<id_lizenz>` (Phase 3 der
   Saison-Transaktion). Status 1:1 (`Vocab::LIZENZSTATUS_TO_STATUS_ID`).
   `Transformer.license_attrs` ist unit-getestet; der Merge selbst läuft gegen die DB.
6. ✅ **Stammdaten-Anlage Vereine/Spielorte** – fehlende `clubs`/`arenas` werden
   beim Import angelegt (`Transformer.club_attrs`/`arena_attrs`), wenn kein
   normalisierter Namens-Treffer existiert. Idempotent über den Namensindex
   (frisch Angelegte werden registriert). Export/`legacy:league` liefern volle
   `vereine`/`spielorte`-Datensätze.
7. ✅ **Spieler-Anlage** – Aufstellungs-/Lizenz-Spieler ohne Match werden angelegt
   (`Transformer.player_attrs`, `global_spieler` → `players`), **konservativ nur mit
   Geburtsdatum** (sonst denormalisiert im Lineup). Idempotent über den
   Namensindex (Name+Geburtsdatum) → mehr Lizenzen docken an. Schiedsrichter
   bleiben Freitext (keine Anlage).

### Deployment-Checkliste (echter Prod-Import)

1. **`legacy:prepare` ausführen** (read-only Preflight): prüft, ob `Setting.seasons`
   die Keys 2–5 führt, ob Strafen ein `mapping` haben und ob die
   ID-Schwellen kollidieren.
2. **ID-Schwellen / Reihenfolge** ⚠ wichtigste Entscheidung: `Team.current_season`
   filtert über `league_id >= current_min_league`. Frisch importierte Legacy-Teams
   bekommen die höchsten IDs und würden bei `current_min_league > 0` in der
   aktuellen Saison auftauchen. Daher Altdaten **vor** dem Anlegen der laufenden
   Saison importieren – oder die min-Schwellen danach prüfen. (`League.current_season`
   filtert dagegen über `season_id` und ist nicht betroffen.) Das Archiv-Muster
   für Saisons 6–16 existiert bereits und funktioniert genauso.
3. **`mysql2` ins Gemfile** (`:development`) für den Direktzugriff – oder den
   JSON-Bundle-Weg (`export_bundle.sh` + `legacy:dir`) beibehalten.
4. **Cache invalidieren**: nach dem Import `Rails.cache.delete('settings/init')`.

### Verbleibende Grenzen / bewusste Auslassungen

- **Schiris** werden als Freitext übernommen (`referee1_string`/`referee2_string` aus
  `spielbericht`); bewusst **keine** Verknüpfung zu `referees` (kein `referee_ids`).
- **`nwuv` 2013/14**: Im MariaDB-Dump fehlt die `begegnung`-Tabelle. Die Spiele
  werden stattdessen aus den Ergebnis-Caches der Alt-PHP-App rekonstruiert – siehe
  Abschnitt „Sonderfall NWUV 2013/14". 8 Begegnungen mit Events aber ohne
  Cache-Zeile bleiben ausgelassen (kein Team-/Datum-Link).
- **Spieler ohne Geburtsdatum** im Neusystem bzw. Namensdubletten bleiben
  ungematcht (denormalisierter Name im Lineup erhalten; 78–98 % je Verband).
- **Vereine/Spielorte** werden bei fehlendem Treffer angelegt. **Spieler** ebenfalls,
  aber konservativ **nur mit Geburtsdatum** – ohne Geburtsdatum bleibt der Lineup-Eintrag
  denormalisiert (Dubletten-Risiko mit Live-Karrieren bewusst begrenzt; das vorhandene
  `merged_into_id`-Sicherheitsnetz erlaubt nachträgliches Zusammenführen).
- **Schiedsrichter** bleiben Freitext (kein Anlegen, kein `referee_ids`) – bewusst.
- **Idempotenz nur bei stabiler Eingabe**: Der Upsert (per `legacy_ref`) legt an
  und aktualisiert, **löscht aber nie**. Schrumpft die Quelle (korrigierter Dump
  ohne eine zuvor importierte Liga/Spiel), bleibt der alte Datensatz als Waise
  stehen – ein echter Re-Import braucht ggf. einen separaten Aufräumschritt.
  Dasselbe gilt für **Lizenzen**: Der Merge dedupliziert pro Spieler über die
  license-`id` (`LIC:…`); matcht eine `id_spieler` zwischen zwei Läufen auf einen
  anderen Spieler (geänderter `player_index`), bleibt der alte Eintrag beim zuvor
  gematchten Spieler stehen. Betreuer/Spielbericht werden beim Re-Run überschrieben,
  aber bei entfernter Quell-Zeile nicht zurückgesetzt.

## Sonderfall NWUV 2013/14 (rekonstruierte Begegnungen)

Der MariaDB-Dump `saison201314.sql` enthält für **NWUV (NRW)** keine Tabelle
`nwuv_2013_2014_begegnung` (weder `CREATE` noch `INSERT`). Vorhanden – aber
verwaist – sind `liga` (13), `mannschaft` (67), `spieltag` (94, datiert),
`ereignis` (~5.700), `mitspieler` (~6.800), `spielbericht`, `lizenz`. Ohne die
`begegnung` fehlt der Verbindungssatz „welche zwei Teams, welcher Spieltag" → der
normale Import legt Ligen/Teams an, schreibt aber **0 Spiele** (der Importer ist
begegnung-getrieben). Alle anderen Verbände × Saisons sind vollständig; das Loch
ist isoliert auf `nwuv_2013_2014`.

**Rettungsquelle:** die vorgerenderten Ergebnis-Caches der Alt-PHP-App im
Webspace-Backup `vhosts.tar.bz2`:

```
vhosts/floorball-verband.de/saison2013-14/nwuv/tables/<id_liga>_<spieltag_nr>_matches.tab
```

Semikolon-CSV je Zeile: `heim;gast;heim_tore;gast_tore[ (n.V.)|(forfait)];…;id_begegnung`.
Der Dateiname liefert `id_liga` + `spieltag_nr`, die letzte Spalte die
`id_begegnung` (identisch zu den verwaisten `ereignis`/`mitspieler`).

**Rekonstruktion** (`lib/tasks/legacy_import/reconstruct_nwuv_2013_2014.py`):

- `id_spieltag` ← Lookup `(id_liga, spieltag_nr)` in `spieltag` → **Datum + Halle
  vollständig wiederhergestellt** (100 % Abdeckung der 90 gespielten Spieltage).
- `id_mannschaft1/2` ← Lookup `(id_liga, normalisierter Name)` in `mannschaft`
  (66/66 Teams eindeutig, keine Kollisionen).
- `forfeit` ← 1 wenn Heim 0 & `(forfait)`, 2 wenn Gast 0.
- `ereignis`/`mitspieler`/`betreuer`/`spielbericht` docken per `id_begegnung` an.

Das Skript erzeugt ein Bundle in **exakt dem Schema von `export_all.sql.tmpl`** →
Import über den **unveränderten** `legacy:bundle`-Task. Ablauf:

```bash
# 1. Ergebnis-Caches aus dem Webspace-Backup extrahieren
tar -xjf vhosts.tar.bz2 --strip-components=4 \
    vhosts/floorball-verband.de/saison2013-14/nwuv/tables -C /tmp/nwuv

# 2. Bundle rekonstruieren (schreibt JSON + Report)
python3 lib/tasks/legacy_import/reconstruct_nwuv_2013_2014.py \
    --sql  /pfad/saison201314.sql \
    --tabs /tmp/nwuv/tables \
    --out  /tmp/nwuv_2013_2014_bundle.json

# 3. Dry-Run, dann Import (idempotent; ergänzt die bereits vorhandenen Ligen/Teams)
bundle exec rake legacy:bundle BUNDLE=/tmp/nwuv_2013_2014_bundle.json          # Dry-Run
bundle exec rake legacy:bundle BUNDLE=/tmp/nwuv_2013_2014_bundle.json WRITE=1  # schreibt
```

**Ergebnis:** 366 Spiele, davon 23 Forfait; 342/343 Endstände decken sich exakt
mit dem Event-Log (1 Spiel mit abgeschnittenem Event-Log in der Quelle, beg 810).

**Bewusste Auslassungen:**
- 8 Begegnungen (423, 426, 431, 433, 815–818) haben Events/Aufstellungen, aber
  keine Cache-Zeile → kein Team-/Datum-Link, nicht rekonstruiert.
- **Anstosszeit** je Spiel ist in den Caches nicht enthalten (`uhrzeit` bleibt leer;
  das Datum kommt aus dem Spieltag).
