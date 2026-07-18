#!/usr/bin/env python3
"""Rekonstruiert das Alt-Bundle fuer NWUV (NRW) Saison 2013/14.

Sonderfall: Im MariaDB-Dump `saison201314.sql` FEHLT die Tabelle
`nwuv_2013_2014_begegnung` komplett (kein CREATE/INSERT). Die zugehoerigen
Kind-Tabellen `ereignis`/`mitspieler`/`betreuer`/`spielbericht` sind aber
vorhanden und verweisen ueber `id_begegnung` ins Leere. Der normale
Export-Pfad (`export_all.sql.tmpl`) kann NWUV 2013/14 deshalb nicht abbilden.

Rettungsquelle: die vorgerenderten Ergebnis-Caches der Alt-PHP-App unter
`vhosts/floorball-verband.de/saison2013-14/nwuv/tables/<liga>_<spieltag_nr>_matches.tab`.
Format je Zeile (Semikolon):

    heim_name;gast_name;heim_tore;gast_tore[ (n.V.)|(forfait)];<perioden...>;id_begegnung

Daraus wird die fehlende `begegnung` synthetisiert:
  - id_begegnung  = letzte Spalte
  - id_spieltag   = Lookup (id_liga, spieltag_nr) in nwuv_2013_2014_spieltag
                    (Dateiname liefert liga + spieltag_nr -> Datum/Halle zurueck)
  - id_mannschaft1/2 = Lookup (id_liga, normalisierter Name) in _mannschaft
  - forfeit       = 1 wenn Heim 0 & Score "(forfait)", 2 wenn Gast 0, sonst 0
  - uhrzeit/spielnummer/schiedsrichter = unbekannt (nil); Schiris kommen aus
    spielbericht.schiedsrichter1/2

Das Ergebnis ist ein Bundle-JSON in exakt dem Schema, das
`export_all.sql.tmpl` erzeugt -> es wird vom unveraenderten Importer
(`rake legacy:bundle` / `legacy:dir`) konsumiert.

Nicht rekonstruierbar (werden gezaehlt + gemeldet, nicht still verworfen):
  - Begegnungen mit Events aber ohne .tab-Zeile (kein Team-/Datum-Link)
  - Anstosszeit je Spiel (in den Caches nicht enthalten)

Aufruf:
    python3 reconstruct_nwuv_2013_2014.py \
        --sql   /pfad/saison201314.sql \
        --tabs  /pfad/vhosts/.../saison2013-14/nwuv/tables \
        --out   /pfad/nwuv_2013_2014_bundle.json
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

VERBAND = "nwuv"
SEASON = "2013_2014"

# ── MariaDB-Dump-Parser (single-line INSERTs, 'quoted' strings, NULL) ──────────


def _split_tuples(blob):
    i, n = 0, len(blob)
    while i < n:
        while i < n and blob[i] != "(":
            i += 1
        if i >= n:
            break
        i += 1
        start, depth, in_str = i, 0, False
        while i < n:
            c = blob[i]
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == "'":
                    if i + 1 < n and blob[i + 1] == "'":
                        i += 2
                        continue
                    in_str = False
                i += 1
                continue
            if c == "'":
                in_str = True
            elif c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    yield blob[start:i]
                    i += 1
                    break
                depth -= 1
            i += 1


def _parse_fields(body):
    fields, i, n = [], 0, len(body)
    while i <= n:
        while i < n and body[i] in " \t":
            i += 1
        if i >= n:
            break
        if body[i] == "'":
            i += 1
            buf = []
            while i < n:
                ch = body[i]
                if ch == "\\":
                    nxt = body[i + 1] if i + 1 < n else ""
                    buf.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(nxt, nxt))
                    i += 2
                    continue
                if ch == "'":
                    if i + 1 < n and body[i + 1] == "'":
                        buf.append("'")
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(ch)
                i += 1
            fields.append("".join(buf))
        else:
            j = i
            while j < n and body[j] != ",":
                j += 1
            tok = body[i:j].strip()
            if tok.upper() == "NULL":
                fields.append(None)
            elif re.fullmatch(r"-?\d+", tok):
                fields.append(int(tok))
            elif re.fullmatch(r"-?\d+\.\d+", tok):
                fields.append(float(tok))
            else:
                fields.append(tok)
            i = j
        while i < n and body[i] in " \t":
            i += 1
        if i < n and body[i] == ",":
            i += 1
    return fields


def extract_dicts(sql_path, table, columns):
    needle = "INSERT INTO `%s` VALUES " % table
    out = []
    with open(sql_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if needle in line:
                for body in _split_tuples(line.split(needle, 1)[1]):
                    out.append(dict(zip(columns, _parse_fields(body))))
    return out


# Spalten-Reihenfolgen exakt aus den CREATE TABLEs des Dumps.
COLS = {
    "liga": ["id_liga", "id_spielsystem", "id_klasse", "id_kategorie", "id_saison",
             "name", "stichtag", "kurzname", "stichtag_typ", "weiblich", "ordnungsnr"],
    "mannschaft": ["id_mannschaft", "id_verein", "id_liga", "id_betreuer", "name",
                   "kurzname", "genehmigt", "angelegt_von", "angelegt_am", "sg"],
    "spieltag": ["id_spieltag", "id_spielort", "id_liga", "spieltag_nr", "datum"],
    "ereignis": ["id_ereignis", "id_begegnung", "zeile", "nr_team1", "ass_team1",
                 "periode", "zeit", "tore_team1", "tore_team2", "id_strafe",
                 "id_strafcode", "nr_team2", "ass_team2"],
    "mitspieler": ["id_mitspieler", "id_begegnung", "id_spieler", "trikotnr",
                   "torwart", "kapitain", "team", "name", "vorname"],
    "betreuer": ["id_betreuer", "id_begegnung", "betreuer1", "betreuer2", "betreuer3",
                 "betreuer4", "betreuer5", "betreuer1_unterschrift", "team"],
    "spielbericht": ["id_spielbericht", "id_begegnung", "id_schiedsrichter1",
                     "id_schiedsrichter2", "schiedsrichter1", "schiedsrichter2",
                     "schiedsgericht1", "schiedsgericht2", "unterschrift_schiri1",
                     "unterschrift_schiri2", "unterschrift_schiedsgericht1",
                     "unterschrift_schiedsgericht2", "timeout1", "timeout2",
                     "matchstrafe1", "matchstrafe2", "matchstrafe3", "bes_ereignisse",
                     "protest", "unterschrift_kapitain1", "unterschrift_kapitain2",
                     "verlaengerung", "eingetragen_von", "eingetragen_am",
                     "kommentar", "fehler"],
    "lizenz": ["id_lizenz", "id_spieler", "id_mannschaft", "id_klasse",
               "id_kategorie", "weiblich"],
    "lizenzverlauf": ["id_lizenzverlauf", "id_lizenz", "id_lizenzstatus",
                      "timestamp", "id_benutzer"],
    "global_verein": ["id_verein", "id_spartenleiter", "name", "kurzname", "kuerzel",
                      "strasse", "hausnummer", "plz", "ort", "homepage_verein",
                      "homepage_sparte"],
    "global_spielort": ["id_spielort", "id_verein", "name", "strasse", "hausnummer",
                        "plz", "ort", "anfahrt_pkw", "anfahrt_oepnv", "zuschauer",
                        "kommentar"],
    "global_spieler": ["id_spieler", "id_nation", "name", "vorname", "geschlecht",
                       "geb_datum", "strasse", "hausnummer", "plz", "ort", "erstellt"],
}

# Nur die Spalten, die das Bundle-Schema (export_all.sql.tmpl) tatsaechlich fuehrt.
BUNDLE_KEYS = {
    "liga": ["id_liga", "id_spielsystem", "id_klasse", "id_kategorie", "id_saison",
             "name", "kurzname", "stichtag", "weiblich", "ordnungsnr"],
    "mannschaft": ["id_mannschaft", "id_verein", "id_liga", "name", "kurzname",
                   "genehmigt", "sg"],
    "spieltag": ["id_spieltag", "id_spielort", "id_liga", "spieltag_nr", "datum"],
    "ereignis": ["id_ereignis", "id_begegnung", "zeile", "nr_team1", "ass_team1",
                 "periode", "zeit", "tore_team1", "tore_team2", "id_strafe",
                 "id_strafcode", "nr_team2", "ass_team2"],
    "mitspieler": ["id_begegnung", "id_spieler", "trikotnr", "torwart", "kapitain",
                   "team", "name", "vorname"],
    "betreuer": ["id_begegnung", "team", "betreuer1", "betreuer2", "betreuer3",
                 "betreuer4", "betreuer5", "betreuer1_unterschrift"],
    "spielbericht": ["id_begegnung", "schiedsrichter1", "schiedsrichter2",
                     "unterschrift_schiri1", "unterschrift_schiri2",
                     "unterschrift_kapitain1", "unterschrift_kapitain2",
                     "timeout1", "timeout2", "kommentar", "protest", "verlaengerung"],
    "lizenz": ["id_lizenz", "id_spieler", "id_mannschaft", "id_klasse",
               "id_kategorie", "weiblich"],
    "lizenzverlauf": ["id_lizenz", "id_lizenzstatus", "timestamp"],
}


def pick(row, keys):
    return {k: row.get(k) for k in keys}


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip()).lower()


def parse_score(raw):
    """'4 (n.V.)' / '8(forfait)' / '3' -> (goals:int, overtime:bool, forfait:bool)."""
    raw = (raw or "").strip()
    overtime = bool(re.search(r"\(n\.[VP]\.\)", raw))
    forfait = "forfait" in raw.lower()
    m = re.match(r"\s*(\d+)", raw)
    return (int(m.group(1)) if m else 0, overtime, forfait)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sql", required=True, help="Pfad zu saison201314.sql")
    ap.add_argument("--tabs", required=True, help="nwuv/tables Ordner mit *_matches.tab")
    ap.add_argument("--out", required=True, help="Ziel-Bundle-JSON")
    args = ap.parse_args()

    def load(t):
        return extract_dicts(args.sql, "%s_%s_%s" % (VERBAND, SEASON, t), COLS[t]) \
            if t not in ("global_verein", "global_spielort", "global_spieler") \
            else extract_dicts(args.sql, t, COLS[t])

    ligen = load("liga")
    mannschaften = load("mannschaft")
    spieltage = load("spieltag")
    ereignisse = load("ereignis")
    mitspieler = load("mitspieler")
    betreuer = load("betreuer")
    spielberichte = load("spielbericht")
    lizenzen = load("lizenz")
    lizenzverlauf = load("lizenzverlauf")

    # Lookups
    st_by_liga_nr = {(int(s["id_liga"]), int(s["spieltag_nr"])): int(s["id_spieltag"])
                     for s in spieltage}
    team_by_liga_name = {}
    for m in mannschaften:
        team_by_liga_name.setdefault((int(m["id_liga"]), norm(m["name"])), int(m["id_mannschaft"]))

    # ── begegnung aus .tab-Caches synthetisieren ──────────────────────────────
    begegnungen = []
    unresolved_team, missing_spieltag = [], []
    tab_files = sorted(glob.glob(os.path.join(args.tabs, "*_matches.tab")))
    if not tab_files:
        sys.exit("Keine *_matches.tab in %s" % args.tabs)

    seen_bids = set()
    for f in tab_files:
        mo = re.match(r"(\d+)_(\d+)_matches\.tab", os.path.basename(f))
        if not mo:
            continue
        liga, st_nr = int(mo.group(1)), int(mo.group(2))
        id_spieltag = st_by_liga_nr.get((liga, st_nr))
        for line in open(f, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split(";")
            if len(parts) < 4 or not parts[-1].strip().isdigit():
                continue
            bid = int(parts[-1])
            if bid in seen_bids:
                continue
            seen_bids.add(bid)
            home_name, guest_name = parts[0], parts[1]
            hg, _, hg_ff = parse_score(parts[2])
            gg, _, gg_ff = parse_score(parts[3])
            h = team_by_liga_name.get((liga, norm(home_name)))
            g = team_by_liga_name.get((liga, norm(guest_name)))
            if h is None or g is None:
                unresolved_team.append((liga, home_name if h is None else guest_name))
                continue
            if id_spieltag is None:
                missing_spieltag.append((liga, st_nr))
                continue
            forfeit = 0
            if hg_ff or gg_ff:
                forfeit = 1 if hg == 0 else (2 if gg == 0 else 3)
            begegnungen.append({
                "id_begegnung": bid,
                "id_spieltag": id_spieltag,
                "id_mannschaft1": h,
                "id_mannschaft2": g,
                "id_verband_team1": 0,
                "id_verband_team2": 0,
                "uhrzeit": None,
                "schiedsrichter": None,
                "spielnummer": None,
                "forfeit": forfeit,
            })

    beg_ids = {b["id_begegnung"] for b in begegnungen}
    st_to_liga = {int(s["id_spieltag"]): int(s["id_liga"]) for s in spieltage}
    beg_to_liga = {b["id_begegnung"]: st_to_liga[b["id_spieltag"]] for b in begegnungen}

    # ── Waisen: Events/Aufstellungen ohne rekonstruierte Begegnung ────────────
    orphan_events = sorted({int(e["id_begegnung"]) for e in ereignisse} - beg_ids)
    orphan_lineups = sorted({int(m["id_begegnung"]) for m in mitspieler} - beg_ids)

    def by_liga(rows, mapper):
        out = defaultdict(list)
        for r in rows:
            liga = mapper(r)
            if liga is not None:
                out[liga].append(r)
        return out

    mann_by_liga = by_liga(mannschaften, lambda r: int(r["id_liga"]))
    st_by_liga = by_liga(spieltage, lambda r: int(r["id_liga"]))
    beg_by_liga = by_liga(begegnungen, lambda r: beg_to_liga[r["id_begegnung"]])
    er_by_liga = by_liga(ereignisse, lambda r: beg_to_liga.get(int(r["id_begegnung"])))
    ms_by_liga = by_liga(mitspieler, lambda r: beg_to_liga.get(int(r["id_begegnung"])))
    bt_by_liga = by_liga(betreuer, lambda r: beg_to_liga.get(int(r["id_begegnung"])))
    sb_by_liga = by_liga(spielberichte, lambda r: beg_to_liga.get(int(r["id_begegnung"])))

    mann_liga = {int(m["id_mannschaft"]): int(m["id_liga"]) for m in mannschaften}
    lz_by_liga = by_liga(lizenzen, lambda r: mann_liga.get(int(r["id_mannschaft"])))
    lz_ids_by_liga = {liga: {int(lz["id_lizenz"]) for lz in rows} for liga, rows in lz_by_liga.items()}
    lv_by_liga = defaultdict(list)
    for lv in lizenzverlauf:
        for liga, ids in lz_ids_by_liga.items():
            if int(lv["id_lizenz"]) in ids:
                lv_by_liga[liga].append(lv)

    # ── Bundle je Liga zusammensetzen (Schema wie export_all.sql.tmpl) ────────
    league_entries = []
    for liga in ligen:
        lid = int(liga["id_liga"])
        league_entries.append({
            "liga": {**pick(liga, BUNDLE_KEYS["liga"]),
                     "klasse_name": None},  # klasse_name nicht im Dump-Join verfuegbar; Vocab mappt ueber id_klasse
            "mannschaft": [pick(m, BUNDLE_KEYS["mannschaft"]) for m in mann_by_liga.get(lid, [])],
            "spieltag": [pick(s, BUNDLE_KEYS["spieltag"]) for s in st_by_liga.get(lid, [])],
            "begegnung": [pick(b, ["id_begegnung", "id_spieltag", "id_mannschaft1",
                                   "id_mannschaft2", "id_verband_team1", "id_verband_team2",
                                   "uhrzeit", "schiedsrichter", "spielnummer", "forfeit"])
                          for b in beg_by_liga.get(lid, [])],
            "ereignis": [pick(e, BUNDLE_KEYS["ereignis"]) for e in er_by_liga.get(lid, [])],
            "mitspieler": [pick(m, BUNDLE_KEYS["mitspieler"]) for m in ms_by_liga.get(lid, [])],
            "betreuer": [pick(b, BUNDLE_KEYS["betreuer"]) for b in bt_by_liga.get(lid, [])],
            "spielbericht": [pick(s, BUNDLE_KEYS["spielbericht"]) for s in sb_by_liga.get(lid, [])],
            "lizenz": [pick(lz, BUNDLE_KEYS["lizenz"]) for lz in lz_by_liga.get(lid, [])],
            "lizenzverlauf": [pick(lv, BUNDLE_KEYS["lizenzverlauf"]) for lv in lv_by_liga.get(lid, [])],
        })

    # ── globale Stammdaten (gefiltert auf referenzierte IDs) ───────────────────
    verein_ids = {int(m["id_verein"]) for m in mannschaften if m["id_verein"]}
    spielort_ids = {int(s["id_spielort"]) for s in spieltage if s["id_spielort"]}
    spieler_ids = {int(m["id_spieler"]) for m in mitspieler
                   if m["id_spieler"] and int(m["id_spieler"]) > 0 and int(m["id_begegnung"]) in beg_ids}

    vereine = {str(int(v["id_verein"])): pick(v, ["name", "kurzname", "kuerzel", "strasse",
                                                  "hausnummer", "plz", "ort"])
               for v in load("global_verein") if int(v["id_verein"]) in verein_ids}
    spielorte = {str(int(o["id_spielort"])): pick(o, ["name", "strasse", "hausnummer", "plz", "ort"])
                 for o in load("global_spielort") if int(o["id_spielort"]) in spielort_ids}
    spieler = {str(int(sp["id_spieler"])): pick(sp, ["name", "vorname", "geb_datum", "geschlecht"])
               for sp in load("global_spieler") if int(sp["id_spieler"]) in spieler_ids}

    bundle = {
        "verband": VERBAND,
        "season": SEASON,
        "leagues": league_entries,
        "vereine": vereine,
        "spielorte": spielorte,
        "spieler": spieler,
    }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(bundle, fh, ensure_ascii=False, indent=1)

    # ── Report ────────────────────────────────────────────────────────────────
    n_ff = sum(1 for b in begegnungen if b["forfeit"])
    print("### NWUV 2013/14 Rekonstruktion ###")
    print("Ligen:            %d" % len(league_entries))
    print("Begegnungen:      %d rekonstruiert (davon %d Forfait)" % (len(begegnungen), n_ff))
    print("Ereignis-Zeilen:  %d" % sum(len(e["ereignis"]) for e in league_entries))
    print("Mitspieler-Zeilen:%d" % sum(len(e["mitspieler"]) for e in league_entries))
    print("Lizenzen:         %d" % sum(len(e["lizenz"]) for e in league_entries))
    print("Vereine/Spielorte/Spieler: %d / %d / %d" % (len(vereine), len(spielorte), len(spieler)))
    if unresolved_team:
        print("!! Unaufloesbare Teams: %d -> %s" % (len(unresolved_team), unresolved_team[:10]))
    if missing_spieltag:
        print("!! Ohne Spieltag/Datum: %d -> %s" % (len(missing_spieltag), missing_spieltag[:10]))
    if orphan_events:
        print("HINWEIS: %d Begegnungen haben Events/Aufstellungen, aber KEINE .tab-Zeile "
              "(kein Team-/Datum-Link, NICHT rekonstruiert): %s" % (len(orphan_events), orphan_events))
    print("Bundle geschrieben: %s" % args.out)


if __name__ == "__main__":
    main()
