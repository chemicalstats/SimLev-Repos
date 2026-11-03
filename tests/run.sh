#!/usr/bin/env bash
# tests/run.sh – Tests nach Zweck gegen die gebauten bzw. installierten Pakete.
#
#   tests/run.sh [--bauen] [r] [python] [julia] [methodik] [gleichlauf] [fehler] [ausgabe] [schnittstelle]
#                [--api] [--gleichlauf-lauf]                                         (aus einem beliebigen Ordner)
#
# Sprachen (ohne Angabe alle drei) und Gruppen (ohne Angabe alle) frei kombinierbar; je Sprache ein Einstieg:
#   R       Rscript tests/run.R <gruppen>                 (methodik, fehler, ausgabe, schnittstelle; testthat)
#   Python  python3 -m pytest tests/<gruppe> ...          (gleichlauf, fehler, ausgabe, schnittstelle)
#   Julia   julia --project=julia tests/run.jl <gruppen>  (gleichlauf, fehler, ausgabe, schnittstelle)
# Gruppen, die es in einer Sprache nicht gibt, entfallen dort (methodik nur in R; gleichlauf hat R als Herkunft).
# --api: Schnittstellenvergleich der drei Sprachen (tests/schnittstelle/run.sh --check). --gleichlauf-lauf:
# tests/werkzeuge/gleichlauf/run.sh --quick --no-build (erzeugt die Fälle mit R neu, Zufallsprüfungen). --bauen: vorher
# R in die erste Bibliothek von R_LIBS installieren, Python an Ort und Stelle und Julia (Pkg.build) bauen.
# Voraussetzungen: R mit testthat und jsonlite, Python mit pytest, numpy, pandas, Julia 1.10 oder neuer.
# Ende 1, wenn ein Teil scheitert.
set -uo pipefail
export LC_ALL=C.UTF-8
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bauen=0; api=0; lauf_gl=0; spr=(); gr=()
for a in "$@"; do
  case "$a" in
    --bauen) bauen=1 ;;
    --api) api=1 ;;
    --gleichlauf-lauf) lauf_gl=1 ;;
    r|python|julia) spr+=("$a") ;;
    methodik|gleichlauf|fehler|ausgabe|schnittstelle) gr+=("$a") ;;
    *) echo "run.sh: unbekannt: $a" >&2; exit 2 ;;
  esac
done
if ((${#spr[@]} == 0)) && ((${#gr[@]} == 0)) && ((api || lauf_gl)); then spr=(); else
  ((${#spr[@]})) || spr=(r python julia)
  ((${#gr[@]})) || gr=(methodik gleichlauf fehler ausgabe schnittstelle)
fi
status=0
lauf() { # lauf <name> <befehl ...>
  local name="$1"; shift; local t0=$SECONDS
  echo "== $name"
  if "$@"; then echo "== $name: ok ($((SECONDS - t0)) s)"; else echo "== $name: FEHLER ($((SECONDS - t0)) s)"; status=1; fi
}
nur() { # nur <erlaubte gruppen ...>: gewählte Gruppen, die es in der Sprache gibt
  local x y; for x in "${gr[@]}"; do for y in "$@"; do [[ $x == "$y" ]] && echo "$x"; done; done
}
if ((bauen)); then
  lib="${R_LIBS%%:*}"
  [[ -n $lib ]] || { echo "run.sh --bauen: R_LIBS nicht gesetzt" >&2; exit 2; }
  mkdir -p "$lib"
  lauf "R CMD INSTALL" R CMD INSTALL --preclean -l "$lib" r
  lauf "Python build_ext" bash -c "cd python && python3 setup.py build_ext --inplace --force"
  lauf "Julia Pkg.build" julia --project=julia -e 'using Pkg; Pkg.build()'
fi
for s in "${spr[@]}"; do
  case "$s" in
    r) g=($(nur methodik fehler ausgabe schnittstelle)); ((${#g[@]})) && lauf "R (${g[*]})" Rscript tests/run.R "${g[@]}" ;;
    python) g=($(nur gleichlauf fehler ausgabe schnittstelle)); ((${#g[@]})) &&
              lauf "Python (${g[*]})" python3 -m pytest -q -p no:cacheprovider "${g[@]/#/tests/}" ;;
    julia) g=($(nur gleichlauf fehler ausgabe schnittstelle)); ((${#g[@]})) &&
             lauf "Julia (${g[*]})" julia --project=julia tests/run.jl "${g[@]}" ;;
  esac
done
((api)) && lauf "Schnittstelle (tests/schnittstelle/run.sh --check)" tests/schnittstelle/run.sh --check
((lauf_gl)) && lauf "Gleichlauf-Lauf (tests/werkzeuge/gleichlauf)" tests/werkzeuge/gleichlauf/run.sh --quick --no-build
exit $status
