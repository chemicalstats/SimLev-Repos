#!/usr/bin/env bash
# tools/gleichlauf/run.sh – Gleichlaufprüfung (Etappe 9, Entwurf C.8): Ersatz für die ausgesetzten
# Tests bis zum Neuaufbau. Erzeugt eine Teilmenge der Referenzfälle mit dem aktuellen R neu und
# vergleicht Python und Julia streng dagegen (NA != NaN, Vorzeichen der Null, Ausgaben, Warnungen).
#
#   tools/gleichlauf/run.sh [--quick | --full] [--out ORDNER] [--no-build] [modul ...]
#
#   --quick     jede 20. Fall-Kennung (Prüfsumme, SIMLEV_GEN_SUBSET=20) und kleine Engine-Läufe (Standard)
#   --full      alle Fälle, Engine-Läufe wie golden/README.md (500 bzw. 1000 Zufallsfälle)
#   --out DIR   Arbeitsordner (Standard tools/gleichlauf/out); darin rlib/, modules/, cases/,
#               stress/, Protokolle *.txt und bericht.txt
#   --no-build  R, Python und Julia nicht neu bauen (R-Bibliothek DIR/rlib muss bestehen)
#   modul ...   nur diese Generatoren golden/modules/gen_<modul>.R (und slc), ohne Engine-Läufe
#
# Ausgeschlossen sind die Module, die zu ersetzende R-Routinen prüfen (r_nmath, r_rng, r_linalg,
# r_nlminb, rugarch, evd, imputets) und in r_stats die Fälle zu optim, smooth.spline, density,
# FFT, t.test, lm/lm.fit/poly/glm, summary.lm und optimHess. Zusatzfälle (simlev_seed, Ziehungen
# und Verteilungen der C-Bibliothek slc) in tools/gleichlauf/extra_cases.R (Modul slc); 9.2: Kerne der
# Etappe 9.2 in tools/gleichlauf/extra_cases_92.R (Modul slc_linalg).
# Ende 1, wenn eine Sprache abweicht, ein Schritt scheitert oder core_sync.py --check abweicht.
# Läufe nie parallel im selben Arbeitsordner.
set -uo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

mode=quick; out="$here/out"; build=1; mods=()
while (($#)); do
  case "$1" in
    --quick) mode=quick ;;
    --full) mode=full ;;
    --out) out="$2"; shift ;;
    --no-build) build=0 ;;
    -*) echo "run.sh: unbekannte Option $1" >&2; exit 2 ;;
    *) mods+=("$1") ;;
  esac
  shift
done
EXCLUDE_MODULES=" r_nmath r_rng r_linalg r_nlminb rugarch evd imputets "
R_STATS_EXCLUDE='^(optim|optimhess|ss|density|bw|fft|ttest|lm|lmfit|poly|glm|summary)_'
if [[ $mode == quick ]]; then sub=20; ng=10; ns=20; else sub=1; ng=500; ns=1000; fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"
rep="$out/bericht.txt"; : > "$rep"
status=0
note() { echo "$*" | tee -a "$rep"; }
step() { # step <name> <protokoll> <befehl ...>
  local name="$1" log="$2"; shift 2
  local t0=$SECONDS
  if "$@" > "$log" 2>&1; then note "ok      $name ($((SECONDS - t0)) s)"; return 0; fi
  note "FEHLER  $name ($((SECONDS - t0)) s; Protokoll $log)"; status=1; return 1
}

note "Gleichlauf $mode ($(date -Iseconds)), Arbeitsordner $out"
# 1. Bauen
if ((build)); then
  mkdir -p "$out/rlib"
  step "R CMD INSTALL" "$out/r_install.txt" R CMD INSTALL -l "$out/rlib" r
  step "Python build_ext --inplace" "$out/py_build.txt" bash -c "cd python && python3 setup.py build_ext --inplace"
  step "Julia Pkg.build" "$out/jl_build.txt" julia --project=julia -e 'using Pkg; Pkg.build()'
fi
step "core_sync --check" "$out/core_sync.txt" python3 tools/core_sync.py --check

# 2. Fälle erzeugen
export R_LIBS="$out/rlib"
rm -rf "$out/modules"; mkdir -p "$out/modules"
if ((${#mods[@]} == 0)); then
  for g in golden/modules/gen_*.R; do m="${g#golden/modules/gen_}"; m="${m%.R}"; mods+=("$m"); done
  engine=1
else
  engine=0
fi
gen=()
for m in "${mods[@]}"; do
  [[ "$EXCLUDE_MODULES" == *" $m "* ]] && { note "aus     $m (prüft eine zu ersetzende R-Routine)"; continue; }
  [[ -f golden/modules/gen_$m.R ]] || { note "FEHLER  Generator gen_$m.R fehlt"; status=1; continue; }
  ex=""; [[ $m == r_stats ]] && ex="$R_STATS_EXCLUDE"
  step "erzeugen $m" "$out/gen_$m.txt" env SIMLEV_MODULE_DIR="$out/modules" SIMLEV_GEN_SUBSET=$sub \
       SIMLEV_GEN_EXCLUDE="$ex" Rscript "golden/modules/gen_$m.R" && gen+=("$m")
done
step "erzeugen slc (extra_cases.R)" "$out/gen_slc.txt" env SIMLEV_MODULE_DIR="$out/modules" Rscript tools/gleichlauf/extra_cases.R \
  && gen+=("slc")
# 9.2: Zusatzfälle der Etappe 9.2 (Modul slc_linalg: lineare Algebra, Matrixprodukt, kleinste Quadrate, Stineman, Spline, Kerndichte)
step "erzeugen slc_linalg (extra_cases_92.R)" "$out/gen_slc_linalg.txt" env SIMLEV_MODULE_DIR="$out/modules" \
  Rscript tools/gleichlauf/extra_cases_92.R && gen+=("slc_linalg")

# 9.3: Optimierer der C-Bibliothek slc (Modul slc_opt)
step "erzeugen slc_opt (extra_cases_opt.R)" "$out/gen_slc_opt.txt" env SIMLEV_MODULE_DIR="$out/modules" Rscript tools/gleichlauf/extra_cases_opt.R \
  && gen+=("slc_opt")
# 9.4: Modelle der C-Bibliothek slc (Modul slc_models: GARCH/GJR, GPD, DCC, MS-GARCH und HMM, Bootstrap-Kerne)
step "erzeugen slc_models (extra_cases_94.R)" "$out/gen_slc_models.txt" env SIMLEV_MODULE_DIR="$out/modules" Rscript tools/gleichlauf/extra_cases_94.R \
  && gen+=("slc_models")
# leere Module (keine Fälle in der Teilmenge) nicht vergleichen
cmp=()
for m in "${gen[@]}"; do
  if compgen -G "$out/modules/$m/*.json.gz" > /dev/null; then cmp+=("$m"); fi
done

# 3. Vergleichen
if ((${#cmp[@]})); then
  step "Python compare_reference" "$out/py_ref.txt" python3 python/tools/compare_reference.py --dir "$out/modules" "${cmp[@]}"
  step "Julia compare_reference" "$out/jl_ref.txt" julia --project=julia julia/tools/compare_reference.jl --dir "$out/modules" "${cmp[@]}"
fi

# 4. Engine
if ((engine)); then
  rm -rf "$out/cases" "$out/stress"
  step "erzeugen Engine golden_cases.R ($ng)" "$out/gen_golden.txt" Rscript golden/golden_cases.R "$out/cases" $ng 4711
  step "erzeugen Engine stress_cases.R ($ns)" "$out/gen_stress.txt" Rscript golden/stress_cases.R "$out/stress" $ns 90210
  step "Python compare_golden" "$out/py_gold.txt" python3 python/tools/compare_golden.py -q "$out/cases" "$out/stress"
  step "Julia compare_golden" "$out/jl_gold.txt" julia --project=julia julia/tools/compare_golden.jl "$out/cases" "$out/stress"
fi

# 5. Abdeckung (Bericht; Ziel 0 Exporte ohne Fall)
python3 tools/gleichlauf/coverage.py --dir "$out/modules" > "$out/coverage.txt" 2>&1
note "        $(head -n 1 "$out/coverage.txt")"

# 6. Zusammenfassung
note ""
for f in py_ref jl_ref; do
  [[ -f "$out/$f.txt" ]] || continue
  note "== $f"; grep -E "bitgleich|^Gesamt" "$out/$f.txt" | tee -a "$rep" > /dev/null
  grep -E "^Gesamt" "$out/$f.txt" | sed 's/^/   /'
done
for f in py_gold jl_gold; do
  [[ -f "$out/$f.txt" ]] || continue
  note "== $f"; grep -E "Fälle bitgleich|gesamt" "$out/$f.txt" | tee -a "$rep"
done
if ((status)); then note "Gleichlauf: ABWEICHUNG oder Fehler (siehe oben)"; else note "Gleichlauf: R, Python und Julia gleich"; fi
exit $status
