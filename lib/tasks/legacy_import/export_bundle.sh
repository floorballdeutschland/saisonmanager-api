#!/usr/bin/env bash
# Exportiert alle Ligen eines <verband>_<saison> aus der Alt-MariaDB als
# JSON-Bundle nach OUT_DIR (Default: <repo>/tmp/legacy, gitignored).
#
#   export_bundle.sh <VERBAND> <SEASON> <DB> [MYSQL_CONTAINER] [MYSQL_PASS]
#   Beispiel: export_bundle.sh fvd 2013_2014 saison201314
#
# Hinweis: mysql --raw ist zwingend – ohne escapt der Batch-Modus Backslashes
# doppelt und zerbricht JSON-Strings mit Sonderzeichen.
set -euo pipefail
VERBAND="$1"; SEASON="$2"; DB="$3"
CONTAINER="${4:-sm_legacy_mariadb}"
PASS="${5:-legacy}"
PFX="${VERBAND}_${SEASON}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/../../../tmp/legacy}" # bundles NICHT ins Repo
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/${PFX}_bundle.json"

sed -e "s/__VERBAND__/${VERBAND}/g" \
    -e "s/__SEASON__/${SEASON}/g" \
    -e "s/__PFX__/${PFX}/g" \
    "$SCRIPT_DIR/export_all.sql.tmpl" \
  | docker exec -i "$CONTAINER" mariadb -uroot -p"$PASS" "$DB" -N -B --raw \
  > "$OUT"

echo "OK  $PFX  ($(($(stat -c%s "$OUT") / 1024)) KB) → $OUT"
