#!/usr/bin/env bash
# tests/werkzeuge/doku/beispiele.sh – führt alle Beispiele der Tutorials und READMEs in R, Python und Julia aus.
#
#   tests/werkzeuge/doku/beispiele.sh [--write] [r] [python] [julia]      (aus einem beliebigen Ordner)
#
# Sprachen ohne Angabe: alle drei. Geprüft werden README.md (Wurzel, r/, python/, julia/), die Vignette
# r/vignettes/getting-started.Rmd, die Tutorials python/examples/tutorial.md und julia/examples/tutorial.md
# sowie die Skripte python/examples/*.py und julia/examples/*.jl. Ausgabeblöcke ```text hinter einem
# Codeblock werden verglichen (Regeln in beispiele.py); --write schreibt abweichende Ausgaben neu. Im
# Haupt-README müssen die Ausgaben außerdem in R, Python und Julia gleich sein (Marke "gleiche Ausgaben").
# Die Abbildungen des Haupt-README schreibt tests/werkzeuge/doku/bilder.py.
# Voraussetzung: gebaute bzw. installierte Pakete wie für tests/run.sh (R aus R_LIBS, Python an Ort und
# Stelle gebaut, Julia nach Pkg.build). Ende 1, wenn ein Beispiel scheitert oder eine Ausgabe abweicht.
set -uo pipefail
export LC_ALL=C.UTF-8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root"
args=(); spr=()
for a in "$@"; do
  case "$a" in
    --write) args+=(--write) ;;
    r|python|julia) spr+=("$a") ;;
    *) echo "beispiele.sh: unbekannt: $a" >&2; exit 2 ;;
  esac
done
((${#spr[@]})) || spr=(r python julia)
args+=(--sprache "$(IFS=,; echo "${spr[*]}")")
dateien=(README.md r/README.md python/README.md julia/README.md r/vignettes/getting-started.Rmd
         python/examples/tutorial.md julia/examples/tutorial.md python/examples/*.py julia/examples/*.jl)
python3 "$root/tests/werkzeuge/doku/beispiele.py" "${args[@]}" "${dateien[@]}"
