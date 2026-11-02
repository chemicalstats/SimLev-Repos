#!/usr/bin/env bash
# tools/gleichlauf/run.sh – Gleichlaufprüfung (Etappe 9, Entwurf C.8): Ersatz für die ausgesetzten
# Tests bis zum Neuaufbau. Erzeugt eine Teilmenge der Referenzfälle mit dem aktuellen R neu und
# vergleicht Python und Julia streng dagegen (NA != NaN, Vorzeichen der Null, Ausgaben, Warnungen).
#
#   tools/gleichlauf/run.sh [--quick | --full] [--out ORDNER] [--no-build] [modul ...]
#
#   --quick     jede 20. Fall-Kennung (Prüfsumme, SIMLEV_GEN_SUBSET=20), kleine Engine-Läufe und kleine
#               Zufallsprüfungen (Standard)
#   --full      alle Fälle, Engine-Läufe wie golden/README.md (500 bzw. 1000 Zufallsfälle), volle Zufallsprüfungen
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
# N11: Zufallsprüfungen mit R als Orakel (Schritt 5; ohne Modulliste immer, mit Modulliste nur bei --full), je
# Python und Julia gegen R, Ergebnis in bericht.txt und im Exit-Code:
#   date_fuzz.R + _cmp.{py,jl} Datumsformat (auch Schalter, %OS), as.Date  quick 500, full 10000 Formate (+ Hälfte %OS)
#   rbase_fuzz.R + _cmp.{py,jl} Kerne core/slc_rbase*.c (Summen, order …)  quick 200, full 5000 Fälle je Kern
#   tariff_fuzz.R (T14)        Tarifkern core/tariff_core_impl.h gegen      quick 200, full 10000 Fälle je Teil
#                              .tariff_income_tax/.tariff_soli/.tariff_close (nur R; Kern in allen Sprachen gleich)
#   sim_fuzz.R (E17)           simulation() mit allen Bausteinen; Referenz  quick 300, full 2000 Fälle
#                              aus R 1.3.0 (Pflicht: SIMLEV_FUZZ_REFLIB, Standard /home/claude/rlib130), dagegen
#                              R neu (sim_fuzz_cmp.py), Python und Julia (compare_reference); bitgleich mit
#                              Ausgabe, print(), Warnungen und Fehlertexten; seit E17 Stufe 1c alle Läufe über
#                              den Kern, auch mit details (engine_nan_fuzz der entfallenen Engine-Kerne entfällt)
#   sched_fuzz.R (E17 Stufe 2) Datums-Fuzz der Vorbereitung im Kern         quick 300, full 2000 Fälle
#                              (core/prepare_core_impl.h): calculate_dates_flags() direkt und simulation() mit
#                              Schwerpunkt Kalender (Lücken, Monatsenden, Schalttage, Termine, Freibetrag);
#                              Referenz aus R 1.3.0 wie sim_fuzz (Pflicht), Vergleich wie sim_fuzz
#   metric_fuzz.R (E17 Stufe 3) Fuzz der Kennzahlen (Auswertung im Kern     quick 300, full 2000 Fälle
#                              core/evaluate_core_impl.h): .xirr_rate direkt und simulation() mit Schwerpunkt
#                              Renditen, XIRR, Drawdowns, risk_free, offene Steuerschuld, undefined_metrics;
#                              Referenz aus R 1.3.0 wie sim_fuzz (Pflicht), Vergleich wie sim_fuzz
# Arbeitsordner DIR/fuzz/{date,rbase,sim_ref,sim_new,sched_ref,sched_new,metric_ref,metric_new}.
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
if [[ $mode == quick ]]; then sub=20; ng=10; ns=20; fz_date=500; fz_rb=200; fz_tt=200; fz_sim=300; fz_sched=300; fz_met=300
else sub=1; ng=500; ns=1000; fz_date=10000; fz_rb=5000; fz_tt=10000; fz_sim=2000; fz_sched=2000; fz_met=2000; fi
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
  step "R CMD INSTALL" "$out/r_install.txt" R CMD INSTALL --preclean -l "$out/rlib" r   # --preclean: make kennt die Header-Abhaengigkeiten nicht
  step "Python build_ext --inplace" "$out/py_build.txt" bash -c "cd python && python3 setup.py build_ext --inplace --force"
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

# 5. Zufallsprüfungen (N11): Datumskern, slc_rbase-Kerne, Tarifkern, simulation(); R als Orakel
if ((engine)) || [[ $mode == full ]]; then
  fz="$out/fuzz"; rm -rf "$fz"; mkdir -p "$fz/date" "$fz/rbase"
  if step "erzeugen date_fuzz ($fz_date)" "$out/fz_date_gen.txt" Rscript tools/gleichlauf/date_fuzz.R "$fz/date" $fz_date; then
    step "Python date_fuzz" "$out/fz_date_py.txt" python3 tools/gleichlauf/date_fuzz_cmp.py "$fz/date"
    step "Julia date_fuzz" "$out/fz_date_jl.txt" julia --project=julia tools/gleichlauf/date_fuzz_cmp.jl "$fz/date"
  fi
  if step "erzeugen rbase_fuzz ($fz_rb je Kern)" "$out/fz_rbase_gen.txt" Rscript tools/gleichlauf/rbase_fuzz.R "$fz/rbase" $fz_rb; then
    step "Python rbase_fuzz" "$out/fz_rbase_py.txt" python3 tools/gleichlauf/rbase_fuzz_cmp.py "$fz/rbase"
    step "Julia rbase_fuzz" "$out/fz_rbase_jl.txt" julia --project=julia tools/gleichlauf/rbase_fuzz_cmp.jl "$fz/rbase"
  fi
  step "R tariff_fuzz ($fz_tt je Teil)" "$out/fz_tariff.txt" Rscript tools/gleichlauf/tariff_fuzz.R $fz_tt 20261101
  # E17: Zufallsfälle über simulation(); Referenz aus R 1.3.0 ist Pflicht (fehlt sie, scheitert der Schritt)
  reflib="${SIMLEV_FUZZ_REFLIB:-/home/claude/rlib130}"
  rm -rf "$fz/sim_ref" "$fz/sim_new"; mkdir -p "$fz/sim_ref" "$fz/sim_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  sim_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen sim_fuzz Referenz R 1.3.0 ($fz_sim)" "$out/fz_sim_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_MODULE_DIR="$fz/sim_ref" Rscript tools/gleichlauf/sim_fuzz.R $fz_sim 20261101 \
     && step "erzeugen sim_fuzz R neu ($fz_sim)" "$out/fz_sim_new.txt" \
         env SIMLEV_MODULE_DIR="$fz/sim_new" Rscript tools/gleichlauf/sim_fuzz.R $fz_sim 20261101; then
    step "Vergleich sim_fuzz R neu gegen R 1.3.0" "$out/fz_sim_r.txt" \
      python3 -I tools/gleichlauf/sim_fuzz_cmp.py "$fz/sim_ref/sim_fuzz" "$fz/sim_new/sim_fuzz"
    step "Python sim_fuzz gegen R 1.3.0" "$out/fz_sim_py.txt" python3 python/tools/compare_reference.py --dir "$fz/sim_ref" sim_fuzz
    step "Julia sim_fuzz gegen R 1.3.0" "$out/fz_sim_jl.txt" julia --project=julia julia/tools/compare_reference.jl --dir "$fz/sim_ref" sim_fuzz
  fi
  # E17 Stufe 2: Datums-Fuzz der Vorbereitung (Termine, Kalender, Flags im Kern); Referenz aus R 1.3.0 (Pflicht)
  rm -rf "$fz/sched_ref" "$fz/sched_new"; mkdir -p "$fz/sched_ref" "$fz/sched_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  sched_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen sched_fuzz Referenz R 1.3.0 ($fz_sched)" "$out/fz_sched_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_MODULE_DIR="$fz/sched_ref" Rscript tools/gleichlauf/sched_fuzz.R $fz_sched 20261102 \
     && step "erzeugen sched_fuzz R neu ($fz_sched)" "$out/fz_sched_new.txt" \
         env SIMLEV_MODULE_DIR="$fz/sched_new" Rscript tools/gleichlauf/sched_fuzz.R $fz_sched 20261102; then
    step "Vergleich sched_fuzz R neu gegen R 1.3.0" "$out/fz_sched_r.txt" \
      python3 -I tools/gleichlauf/sim_fuzz_cmp.py "$fz/sched_ref/sched_fuzz" "$fz/sched_new/sched_fuzz"
    step "Python sched_fuzz gegen R 1.3.0" "$out/fz_sched_py.txt" python3 python/tools/compare_reference.py --dir "$fz/sched_ref" sched_fuzz
    step "Julia sched_fuzz gegen R 1.3.0" "$out/fz_sched_jl.txt" julia --project=julia julia/tools/compare_reference.jl --dir "$fz/sched_ref" sched_fuzz
  fi
  # E17 Stufe 3: Fuzz der Kennzahlen (Auswertung im Kern); Referenz aus R 1.3.0 (Pflicht)
  rm -rf "$fz/metric_ref" "$fz/metric_new"; mkdir -p "$fz/metric_ref" "$fz/metric_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  metric_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen metric_fuzz Referenz R 1.3.0 ($fz_met)" "$out/fz_metric_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_MODULE_DIR="$fz/metric_ref" Rscript tools/gleichlauf/metric_fuzz.R $fz_met 20261103 \
     && step "erzeugen metric_fuzz R neu ($fz_met)" "$out/fz_metric_new.txt" \
         env SIMLEV_MODULE_DIR="$fz/metric_new" Rscript tools/gleichlauf/metric_fuzz.R $fz_met 20261103; then
    step "Vergleich metric_fuzz R neu gegen R 1.3.0" "$out/fz_metric_r.txt" \
      python3 -I tools/gleichlauf/sim_fuzz_cmp.py "$fz/metric_ref/metric_fuzz" "$fz/metric_new/metric_fuzz"
    step "Python metric_fuzz gegen R 1.3.0" "$out/fz_metric_py.txt" python3 python/tools/compare_reference.py --dir "$fz/metric_ref" metric_fuzz
    step "Julia metric_fuzz gegen R 1.3.0" "$out/fz_metric_jl.txt" julia --project=julia julia/tools/compare_reference.jl --dir "$fz/metric_ref" metric_fuzz
  fi
fi

# 6. Abdeckung (Bericht; Ziel 0 Exporte ohne Fall)
python3 tools/gleichlauf/coverage.py --dir "$out/modules" > "$out/coverage.txt" 2>&1
note "        $(head -n 1 "$out/coverage.txt")"

# 7. Zusammenfassung
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
for f in fz_date_py fz_date_jl fz_rbase_py fz_rbase_jl fz_tariff fz_sim_r fz_sim_py fz_sim_jl fz_sched_r fz_sched_py fz_sched_jl fz_metric_r fz_metric_py fz_metric_jl; do
  [[ -f "$out/$f.txt" ]] || continue
  note "== $f"; grep -E "textgleich|gleich$|gleich \(|^Gesamt|^GESAMT|^sim_fuzz|^[a-z0-9_]+ +[0-9]+ +[0-9]+/[0-9]+" "$out/$f.txt" | tee -a "$rep" > /dev/null
  grep -E "^Gesamt|^GESAMT" "$out/$f.txt" | sed 's/^/   /'
done
if ((status)); then note "Gleichlauf: ABWEICHUNG oder Fehler (siehe oben)"; else note "Gleichlauf: R, Python und Julia gleich"; fi
exit $status
