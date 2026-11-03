#!/usr/bin/env bash
# tests/erzeugen/alle.sh – Referenzfälle des Katalogs tests/faelle mit dem installierten R-Paket neu erzeugen.
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> tests/erzeugen/alle.sh [bereich ...]
#
# Ohne Liste alle Bereiche (je Bereich ein Generator tests/erzeugen/<bereich>.R). Der Bereich engine enthält
# zusätzlich die Engine-Fälle im Engine-Format; sie entstehen einmal mit engine_faelle.R (500 Zufallsfälle,
# Startwert 4711) und engine_stress.R (1000, 90210) in einem Arbeitsordner (SIMLEV_GOLDEN_SRC).
# Abgelegt werden nur die Fälle aus tests/erzeugen/auswahl.txt. Danach: git diff --stat tests/faelle zeigt die
# geänderten Bereiche (die Dateien sind Byte für Byte reproduzierbar); Python und Julia müssen dagegen
# bitgleich sein (tests/run.sh).
set -euo pipefail
export LC_ALL=C.UTF-8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
b=("$@")
if ((${#b[@]} == 0)); then
  for g in tests/erzeugen/*.R; do
    n="$(basename "$g" .R)"
    case "$n" in ref_tools|blocks_from_flat|engine_faelle|engine_stress) continue ;; esac
    b+=("$n")
  done
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for x in "${b[@]}"; do
  if [[ $x == engine && -z ${SIMLEV_GOLDEN_SRC:-} ]]; then
    echo "erzeugen Engine-Fälle (engine_faelle.R 500 4711, engine_stress.R 1000 90210)"
    Rscript tests/erzeugen/engine_faelle.R "$tmp/cases" 500 4711 > /dev/null
    Rscript tests/erzeugen/engine_stress.R "$tmp/stress" 1000 90210 > /dev/null
    export SIMLEV_GOLDEN_SRC="$tmp"
  fi
  echo "erzeugen $x"
  env -u SIMLEV_FAELLE_DIR -u SIMLEV_GEN_SUBSET -u SIMLEV_GEN_ALLE Rscript "tests/erzeugen/$x.R" | tail -n 1
done
