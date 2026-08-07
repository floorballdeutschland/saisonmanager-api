#!/usr/bin/env python3
"""Konvertiert die FD-Excel "Schiedsrichterliste 2025.xlsx" in drei CSVs
für die Rake-Tasks referees2025:report / :sync / :import_history /
:backfill_beendete / :fill_club_ids.

Aufruf:
    python3 scripts/export_schiedsrichterliste_csvs.py <pfad/zur/Schiedsrichterliste.xlsx> [ausgabe-verzeichnis]

Erzeugt im Ausgabe-Verzeichnis (Default: Verzeichnis der Excel):
    referees_stammdaten.csv          – eine Zeile pro Schiedsrichter (alle, mit aktiv-Flag)
    referees_historie.csv            – eine Zeile pro aktivem Schiedsrichter und Jahr (2011-2025)
    referees_historie_beendet.csv    – dasselbe für die Karriere-Beendeten (2007-2025)

Karriere-Regel: Ein Schiedsrichter gilt als aktiv, wenn er in mindestens einem
der letzten fünf Lizenzjahre eine Lizenz hatte – d.h. Spalte AL (vorläufige
Lizenz, gültig bis 31.07.2026) oder die Lizenz-Spalte eines der Jahresblöcke
2024, 2023, 2022 oder 2021 gefüllt ist. Alle anderen gelten als "Karriere
beendet" (aktiv=0).

Die Beendeten stehen in einer eigenen Historien-Datei, weil der Rake-Import
seine Wiederholungssperre am Batch-Namen festmacht: Ihr Lauf braucht
BATCH_SUFFIX, sonst hielte er die bereits importierten Jahres-Batches der
Aktiven für erledigt.

Für die Beendeten werden zusätzlich die Jahresblöcke 2007-2010 ausgewertet. Die
Excel führt sie als "Angaben unvollständig", ohne sie hätten aber 739 statt 92
Datensätze weder Lizenzstufe noch Ablaufdatum. Sie sind deshalb in der
Historien-Datei als unvollstaendig=1 markiert; für Stufe und Ablaufdatum in den
Stammdaten zählen sie mit, denn eine unvollständige Angabe ist hier belastbarer
als gar keine.

Benötigt: pip install openpyxl
"""

import csv
import sys
from datetime import date, datetime
from pathlib import Path

import openpyxl
from openpyxl.utils import column_index_from_string

SHEET = 'aktuelle Übersicht'
FIRST_DATA_ROW = 3

# Spalten des aktuellen Jahres (Kursjahr 2025, Lizenz bis 31.07.2026)
COL_LIZENZNUMMER = 'A'
COL_NACHNAME = 'B'
COL_VORNAME = 'C'
COL_GEBURTSDATUM = 'D'
COL_VEREIN = 'E'
COL_VERBAND = 'F'
COL_KURS1 = ['T', 'U', 'V', 'W']    # Stufe, Datum, Testversion, Punkte
COL_KURS2 = ['X', 'Y', 'Z', 'AA']
COL_VORLAEUFIGE_LIZENZ = 'AL'

# Jahresblöcke: Kursjahr -> Startspalte. Offsets im Block: +3 Kurs, +4 Kursdatum, +5 Lizenz.
YEAR_BLOCKS = {
    2024: 'AS', 2023: 'AZ', 2022: 'BG', 2021: 'BN', 2020: 'BU',
    2019: 'CB', 2018: 'CI', 2017: 'CP', 2016: 'CW', 2015: 'DD',
    2014: 'DK', 2013: 'DR', 2012: 'DY', 2011: 'EF',
}
BLOCK_OFFSET_KURS = 3
BLOCK_OFFSET_KURSDATUM = 4
BLOCK_OFFSET_LIZENZ = 5

# Jahresblöcke, die die Excel selbst als "Angaben unvollständig" überschreibt.
# Nur für die Karriere-Beendeten ausgewertet, dort aber der Unterschied zwischen
# 92 und 739 Datensätzen ohne jede Lizenzangabe.
LEGACY_YEAR_BLOCKS = {2010: 'EM', 2009: 'ET', 2008: 'FA', 2007: 'FH'}

HISTORY_YEARS = sorted(YEAR_BLOCKS, reverse=True)  # 2024..2011; 2025 kommt aus den aktuellen Spalten
LEGACY_YEARS = sorted(LEGACY_YEAR_BLOCKS, reverse=True)  # 2010..2007
ACTIVE_LICENSE_YEARS = [2024, 2023, 2022, 2021]    # zusätzlich zu AL (2025)

# Statt eines Vereins führt die Excel teilweise einen Status. Diese Werte sind
# kein Vereinsname und werden geleert, sonst sucht der Import nach einem Verein
# namens "Karriere beendet" (51 Beendete und 4 Aktive, Stand Juli 2025).
VEREIN_PLATZHALTER = {'karriere beendet', 'ohne verein', 'kein verein'}


def cell(row, letter):
    idx = column_index_from_string(letter) - 1
    return row[idx] if idx < len(row) else None


def clean(value):
    """Excel-Zelle -> String; leere Werte und '-' -> ''."""
    if value is None:
        return ''
    if isinstance(value, (datetime, date)):
        return value.strftime('%d.%m.%Y')
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    text = str(value).strip()
    return '' if text == '-' else text


def block_value(row, year, offset, blocks=YEAR_BLOCKS):
    start = column_index_from_string(blocks[year]) - 1
    idx = start + offset
    return clean(row[idx]) if idx < len(row) else ''


def legacy_value(row, year, offset):
    return block_value(row, year, offset, blocks=LEGACY_YEAR_BLOCKS)


def clean_verein(value):
    """Statustext im Vereinsfeld ist kein Verein."""
    return '' if value.strip().lower() in VEREIN_PLATZHALTER else value


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    xlsx_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else xlsx_path.parent

    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET]

    stammdaten = []
    historie = []
    historie_beendet = []
    skipped_nameless = []

    for row in ws.iter_rows(min_row=FIRST_DATA_ROW, values_only=True):
        lizenznummer = clean(cell(row, COL_LIZENZNUMMER))
        if not lizenznummer:
            continue
        nachname = clean(cell(row, COL_NACHNAME))
        vorname = clean(cell(row, COL_VORNAME))
        if not nachname and not vorname:
            skipped_nameless.append(lizenznummer)
            continue

        geburtsdatum = clean(cell(row, COL_GEBURTSDATUM))
        verein = clean_verein(clean(cell(row, COL_VEREIN)))
        verband = clean(cell(row, COL_VERBAND))
        vorlaeufige_lizenz = clean(cell(row, COL_VORLAEUFIGE_LIZENZ))

        aktiv = bool(vorlaeufige_lizenz) or any(
            block_value(row, year, BLOCK_OFFSET_LIZENZ) for year in ACTIVE_LICENSE_YEARS
        )

        # Aktuelle Lizenzstufe + zugehöriges Kursjahr: AL, sonst jüngster
        # Jahresblock. Bei Beendeten zusätzlich die unvollständigen Blöcke
        # 2007-2010, sonst blieben 647 Datensätze ohne Stufe und Ablaufdatum.
        lizenz, lizenz_jahr = vorlaeufige_lizenz, 2025
        if not lizenz:
            lizenz, lizenz_jahr = '', ''
            for year in HISTORY_YEARS:
                block_lizenz = block_value(row, year, BLOCK_OFFSET_LIZENZ)
                if block_lizenz:
                    lizenz, lizenz_jahr = block_lizenz, year
                    break
            if not lizenz and not aktiv:
                for year in LEGACY_YEARS:
                    block_lizenz = legacy_value(row, year, BLOCK_OFFSET_LIZENZ)
                    if block_lizenz:
                        lizenz, lizenz_jahr = block_lizenz, year
                        break

        stammdaten.append([
            lizenznummer, nachname, vorname, geburtsdatum, verein, verband,
            1 if aktiv else 0, lizenz, lizenz_jahr,
        ])

        ziel = historie if aktiv else historie_beendet

        # Historie 2025 aus den aktuellen Kurs-Spalten (nur wenn Kurs oder Lizenz vorhanden)
        kurs1 = [clean(cell(row, letter)) for letter in COL_KURS1]
        kurs2 = [clean(cell(row, letter)) for letter in COL_KURS2]
        if any(kurs1) or any(kurs2) or vorlaeufige_lizenz:
            ziel.append([lizenznummer, nachname, vorname, geburtsdatum, verein, 2025,
                         *kurs1, *kurs2, vorlaeufige_lizenz, 0])

        if not aktiv:
            for year in LEGACY_YEARS:
                kurs = legacy_value(row, year, BLOCK_OFFSET_KURS)
                kursdatum = legacy_value(row, year, BLOCK_OFFSET_KURSDATUM)
                jahres_lizenz = legacy_value(row, year, BLOCK_OFFSET_LIZENZ)
                if not kurs and not jahres_lizenz:
                    continue
                ziel.append([lizenznummer, nachname, vorname, geburtsdatum, verein, year,
                             kurs, kursdatum, '', '', '', '', '', '', jahres_lizenz, 1])

        for year in HISTORY_YEARS:
            kurs = block_value(row, year, BLOCK_OFFSET_KURS)
            kursdatum = block_value(row, year, BLOCK_OFFSET_KURSDATUM)
            jahres_lizenz = block_value(row, year, BLOCK_OFFSET_LIZENZ)
            if not kurs and not jahres_lizenz:
                continue
            ziel.append([lizenznummer, nachname, vorname, geburtsdatum, verein, year,
                         kurs, kursdatum, '', '', '', '', '', '', jahres_lizenz, 0])

    out_dir.mkdir(parents=True, exist_ok=True)
    stammdaten_path = out_dir / 'referees_stammdaten.csv'
    historie_path = out_dir / 'referees_historie.csv'
    historie_beendet_path = out_dir / 'referees_historie_beendet.csv'

    with open(stammdaten_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f, delimiter=';')
        writer.writerow(['lizenznummer', 'nachname', 'vorname', 'geburtsdatum', 'verein',
                         'verband', 'aktiv', 'lizenz', 'lizenz_jahr'])
        writer.writerows(stammdaten)

    for path, rows in ((historie_path, historie), (historie_beendet_path, historie_beendet)):
        with open(path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f, delimiter=';')
            writer.writerow(['lizenznummer', 'nachname', 'vorname', 'geburtsdatum', 'verein', 'jahr',
                             'kurs1_stufe', 'kurs1_datum', 'kurs1_testversion', 'kurs1_punkte',
                             'kurs2_stufe', 'kurs2_datum', 'kurs2_testversion', 'kurs2_punkte',
                             'lizenz', 'unvollstaendig'])
            writer.writerows(rows)

    aktive = sum(1 for r in stammdaten if r[6] == 1)
    print(f'{stammdaten_path}: {len(stammdaten)} Schiedsrichter '
          f'({aktive} aktiv, {len(stammdaten) - aktive} Karriere beendet)')
    print(f'{historie_path}: {len(historie)} Jahres-Einträge (nur aktive, 2011-2025)')
    unvollstaendig = sum(1 for r in historie_beendet if r[-1] == 1)
    print(f'{historie_beendet_path}: {len(historie_beendet)} Jahres-Einträge '
          f'(Karriere beendet, 2007-2025; davon {unvollstaendig} aus den unvollständigen Blöcken 2007-2010)')
    if skipped_nameless:
        print(f'Übersprungen (ohne Namen): {len(skipped_nameless)} '
              f'Lizenznummern: {", ".join(skipped_nameless[:20])}')


if __name__ == '__main__':
    main()
