#!/usr/bin/env python3
"""Konvertiert die FD-Excel "Schiedsrichterliste 2025.xlsx" in zwei CSVs
für die Rake-Tasks referees_2025:report / :sync / :import_history.

Aufruf:
    python3 scripts/export_schiedsrichterliste_csvs.py <pfad/zur/Schiedsrichterliste.xlsx> [ausgabe-verzeichnis]

Erzeugt im Ausgabe-Verzeichnis (Default: Verzeichnis der Excel):
    referees_stammdaten.csv  – eine Zeile pro Schiedsrichter (alle, mit aktiv-Flag)
    referees_historie.csv    – eine Zeile pro Schiedsrichter und Jahr (2011-2025, nur aktive)

Karriere-Regel: Ein Schiedsrichter gilt als aktiv, wenn er in mindestens einem
der letzten fünf Lizenzjahre eine Lizenz hatte – d.h. Spalte AL (vorläufige
Lizenz, gültig bis 31.07.2026) oder die Lizenz-Spalte eines der Jahresblöcke
2024, 2023, 2022 oder 2021 gefüllt ist. Alle anderen gelten als "Karriere
beendet" (aktiv=0) und werden vom Sync/Historie-Import übersprungen.

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

HISTORY_YEARS = sorted(YEAR_BLOCKS, reverse=True)  # 2024..2011; 2025 kommt aus den aktuellen Spalten
ACTIVE_LICENSE_YEARS = [2024, 2023, 2022, 2021]    # zusätzlich zu AL (2025)


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


def block_value(row, year, offset):
    start = column_index_from_string(YEAR_BLOCKS[year]) - 1
    idx = start + offset
    return clean(row[idx]) if idx < len(row) else ''


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    xlsx_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else xlsx_path.parent

    wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    ws = wb[SHEET]

    stammdaten = []
    historie = []
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
        verein = clean(cell(row, COL_VEREIN))
        verband = clean(cell(row, COL_VERBAND))
        vorlaeufige_lizenz = clean(cell(row, COL_VORLAEUFIGE_LIZENZ))

        # Aktuelle Lizenzstufe + zugehöriges Kursjahr: AL, sonst jüngster Jahresblock.
        lizenz, lizenz_jahr = vorlaeufige_lizenz, 2025
        if not lizenz:
            for year in HISTORY_YEARS:
                block_lizenz = block_value(row, year, BLOCK_OFFSET_LIZENZ)
                if block_lizenz:
                    lizenz, lizenz_jahr = block_lizenz, year
                    break
            else:
                lizenz_jahr = ''

        aktiv = bool(vorlaeufige_lizenz) or any(
            block_value(row, year, BLOCK_OFFSET_LIZENZ) for year in ACTIVE_LICENSE_YEARS
        )

        stammdaten.append([
            lizenznummer, nachname, vorname, geburtsdatum, verein, verband,
            1 if aktiv else 0, lizenz, lizenz_jahr,
        ])

        if not aktiv:
            continue

        # Historie 2025 aus den aktuellen Kurs-Spalten (nur wenn Kurs oder Lizenz vorhanden)
        kurs1 = [clean(cell(row, letter)) for letter in COL_KURS1]
        kurs2 = [clean(cell(row, letter)) for letter in COL_KURS2]
        if any(kurs1) or any(kurs2) or vorlaeufige_lizenz:
            historie.append([lizenznummer, nachname, vorname, geburtsdatum, verein, 2025,
                             *kurs1, *kurs2, vorlaeufige_lizenz])

        for year in HISTORY_YEARS:
            kurs = block_value(row, year, BLOCK_OFFSET_KURS)
            kursdatum = block_value(row, year, BLOCK_OFFSET_KURSDATUM)
            jahres_lizenz = block_value(row, year, BLOCK_OFFSET_LIZENZ)
            if not kurs and not jahres_lizenz:
                continue
            historie.append([lizenznummer, nachname, vorname, geburtsdatum, verein, year,
                             kurs, kursdatum, '', '', '', '', '', '', jahres_lizenz])

    out_dir.mkdir(parents=True, exist_ok=True)
    stammdaten_path = out_dir / 'referees_stammdaten.csv'
    historie_path = out_dir / 'referees_historie.csv'

    with open(stammdaten_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f, delimiter=';')
        writer.writerow(['lizenznummer', 'nachname', 'vorname', 'geburtsdatum', 'verein',
                         'verband', 'aktiv', 'lizenz', 'lizenz_jahr'])
        writer.writerows(stammdaten)

    with open(historie_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f, delimiter=';')
        writer.writerow(['lizenznummer', 'nachname', 'vorname', 'geburtsdatum', 'verein', 'jahr',
                         'kurs1_stufe', 'kurs1_datum', 'kurs1_testversion', 'kurs1_punkte',
                         'kurs2_stufe', 'kurs2_datum', 'kurs2_testversion', 'kurs2_punkte',
                         'lizenz'])
        writer.writerows(historie)

    aktive = sum(1 for r in stammdaten if r[6] == 1)
    print(f'{stammdaten_path}: {len(stammdaten)} Schiedsrichter '
          f'({aktive} aktiv, {len(stammdaten) - aktive} Karriere beendet)')
    print(f'{historie_path}: {len(historie)} Jahres-Einträge (nur aktive, 2011-2025)')
    if skipped_nameless:
        print(f'Übersprungen (ohne Namen): {len(skipped_nameless)} '
              f'Lizenznummern: {", ".join(skipped_nameless[:20])}')


if __name__ == '__main__':
    main()
