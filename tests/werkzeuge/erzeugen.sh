#!/usr/bin/env bash
# tests/werkzeuge/erzeugen.sh – Referenzfälle des Katalogs mit dem installierten R-Paket neu erzeugen.
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> tests/werkzeuge/erzeugen.sh [bereich ...]
#
# Ohne Liste alle Bereiche (je Bereich ein Generator tests/gleichlauf/erzeugen/<bereich>.R). Jeder Generator schreibt
# je Gruppe eine Datei tests/{gleichlauf,fehler,ausgabe}/faelle/<bereich>.jsonl.gz (Format und Auswahl in
# tests/gleichlauf/erzeugen/ref_tools.R). Danach zeigt git diff --stat tests die geänderten Dateien (Byte für Byte
# reproduzierbar); Python und Julia müssen dagegen bitgleich sein (tests/run.sh).
set -euo pipefail
export LC_ALL=C.UTF-8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
b=("$@")
if ((${#b[@]} == 0)); then
  for g in tests/gleichlauf/erzeugen/*.R; do
    n="$(basename "$g" .R)"
    case "$n" in ref_tools|szenario_tools|blocks_from_flat) continue ;; esac
    b+=("$n")
  done
fi
for x in "${b[@]}"; do
  echo "erzeugen $x"
  env -u SIMLEV_FAELLE_DIR -u SIMLEV_GEN_SUBSET -u SIMLEV_GEN_ALLE Rscript "tests/gleichlauf/erzeugen/$x.R" | tail -n 1
done
