#!/usr/bin/env bash
# tests/run.sh – alle Tests des Katalogs tests/ gegen die gebauten bzw. installierten Pakete (T20).
#
#   tests/run.sh [--bauen] [r] [python] [julia] [api] [gleichlauf]      (aus einem beliebigen Ordner)
#
# Ohne Teilliste: r, python, julia (die drei Suiten; Fälle aus tests/faelle). api: tests/api/run.sh --check.
# gleichlauf: tests/gleichlauf/run.sh --quick --no-build (erzeugt die Fälle mit R neu). --bauen: vorher R in die
# erste Bibliothek von R_LIBS installieren, Python an Ort und Stelle und Julia (Pkg.build) bauen.
# Voraussetzungen: R mit testthat und jsonlite, Python mit pytest, numpy, pandas, Julia 1.10 oder neuer.
# Ende 1, wenn ein Teil scheitert.
set -uo pipefail
export LC_ALL=C.UTF-8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bauen=0; teile=()
for a in "$@"; do
  case "$a" in
    --bauen) bauen=1 ;;
    r|python|julia|api|gleichlauf) teile+=("$a") ;;
    *) echo "run.sh: unbekannt: $a" >&2; exit 2 ;;
  esac
done
((${#teile[@]})) || teile=(r python julia)
status=0
lauf() { # lauf <name> <befehl ...>
  local name="$1"; shift; local t0=$SECONDS
  echo "== $name"
  if "$@"; then echo "== $name: ok ($((SECONDS - t0)) s)"; else echo "== $name: FEHLER ($((SECONDS - t0)) s)"; status=1; fi
}
if ((bauen)); then
  lib="${R_LIBS%%:*}"
  [[ -n $lib ]] || { echo "run.sh --bauen: R_LIBS nicht gesetzt" >&2; exit 2; }
  mkdir -p "$lib"
  lauf "R CMD INSTALL" R CMD INSTALL --preclean -l "$lib" r
  lauf "Python build_ext" bash -c "cd python && python3 setup.py build_ext --inplace --force"
  lauf "Julia Pkg.build" julia --project=julia -e 'using Pkg; Pkg.build()'
fi
for t in "${teile[@]}"; do
  case "$t" in
    r) lauf "R (tests/r)" Rscript tests/r/run.R ;;
    python) lauf "Python (tests/python)" python3 -m pytest -q -p no:cacheprovider tests/python ;;
    julia) lauf "Julia (tests/julia)" julia --project=julia tests/julia/runtests.jl ;;
    api) lauf "Schnittstelle (tests/api)" tests/api/run.sh --check ;;
    gleichlauf) lauf "Gleichlauf (tests/gleichlauf)" tests/gleichlauf/run.sh --quick --no-build ;;
  esac
done
exit $status
