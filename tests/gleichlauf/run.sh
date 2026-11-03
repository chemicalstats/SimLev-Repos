#!/usr/bin/env bash
# tests/gleichlauf/run.sh – Gleichlaufprüfung (Etappe 9, Entwurf C.8; seit T20 unter tests/): erzeugt die
# Referenzfälle mit dem aktuellen R neu – alle Fälle der Generatoren, nicht nur die im Katalog abgelegten – und
# vergleicht Python und Julia streng dagegen (NA != NaN, Vorzeichen der Null, Ausgaben, Warnungen).
#
#   tests/gleichlauf/run.sh [--quick | --full] [--out ORDNER] [--no-build] [bereich ...]
#
#   --quick     jede 20. Fall-Kennung (Prüfsumme, SIMLEV_GEN_SUBSET=20), kleine Engine-Läufe und kleine
#               Zufallsprüfungen (Standard)
#   --full      alle Fälle, Engine-Läufe wie im Katalog (500 bzw. 1000 Zufallsfälle), volle Zufallsprüfungen
#               und faelle_diff: die neu erzeugten Katalogdateien müssen Byte für Byte tests/faelle entsprechen
#   --out DIR   Arbeitsordner (Standard tests/gleichlauf/out); darin rlib/, faelle/ (Auswahl wie im Katalog),
#               faelle/alle/ (alle Fälle), cases/, stress/, fuzz/, Protokolle *.txt und bericht.txt
#   --no-build  R, Python und Julia nicht neu bauen (R-Bibliothek DIR/rlib muss bestehen)
#   bereich ... nur diese Generatoren tests/erzeugen/<bereich>.R (engine mit Engine-Läufen)
#
# Schritte: 1 bauen, core/sync.py --check; 2 Engine-Läufe engine_faelle.R/engine_stress.R; 3 Bereiche erzeugen
# (SIMLEV_GEN_ALLE=1); 4 Python und Julia gegen faelle/alle (tests/gleichlauf/vergleich.{py,jl}); 4b faelle_diff
# (nur --full; in der Teilmenge ziehen manche Generatoren ihre Eingaben in anderer Folge); 5 Zufallsprüfungen mit
# R als Orakel (ohne Bereichsliste immer, mit Liste nur bei --full), Fälle werden nicht abgelegt:
#   date_fuzz.R + _cmp.{py,jl} Datumsformat (auch Schalter, %OS), as.Date  quick 500, full 10000 Formate (+ Hälfte %OS)
#   rbase_fuzz.R + _cmp.{py,jl} Kerne core/slc_rbase*.c (Summen, order …)  quick 200, full 5000 Fälle je Kern
#   tariff_fuzz.R (T14)        Tarifkern core/tariff_core_impl.h gegen      quick 200, full 10000 Fälle je Teil
#                              .tariff_income_tax/.tariff_soli/.tariff_close (nur R; Kern in allen Sprachen gleich)
#   sim_fuzz.R (E17)           simulation() mit allen Bausteinen; Referenz  quick 300, full 2000 Fälle
#                              aus R 1.3.0 (Pflicht: SIMLEV_FUZZ_REFLIB, Standard /home/claude/rlib130), dagegen
#                              R neu (sim_fuzz_cmp.py), Python und Julia (vergleich.{py,jl}); bitgleich mit
#                              Ausgabe, print(), Warnungen und Fehlertexten
#   sched_fuzz.R (E17 Stufe 2) Datums-Fuzz der Vorbereitung im Kern         quick 300, full 2000 Fälle
#                              (core/prepare_core_impl.h); Referenz aus R 1.3.0 wie sim_fuzz
#   metric_fuzz.R (E17 Stufe 3) Fuzz der Kennzahlen (core/evaluate_core_impl.h) quick 300, full 2000 Fälle
#                              .xirr_rate direkt und simulation(); Referenz aus R 1.3.0 wie sim_fuzz
# 6 Abdeckung der Exporte durch die Katalogfälle (exporte.py). Ende 1, wenn eine Sprache abweicht, ein Schritt
# scheitert, R vom Katalog abweicht oder core/sync.py --check abweicht. Läufe nie parallel im selben Arbeitsordner.
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
step "core/sync.py --check" "$out/core_sync.txt" python3 core/sync.py --check

# 2. Engine-Läufe (Engine-Format; alle Zufallsfälle werden verglichen, im Katalog liegt die Auswahl)
export R_LIBS="$out/rlib"
mods=("${mods[@]}")
if ((${#mods[@]} == 0)); then
  for g in tests/erzeugen/*.R; do
    m="$(basename "$g" .R)"
    case "$m" in ref_tools|blocks_from_flat|engine_faelle|engine_stress) continue ;; esac
    mods+=("$m")
  done
  engine=1
else
  engine=0
fi
rm -rf "$out/cases" "$out/stress" "$out/faelle"; mkdir -p "$out/faelle"
if [[ " ${mods[*]} " == *" engine "* ]]; then
  step "erzeugen Engine engine_faelle.R ($ng)" "$out/gen_engine_faelle.txt" Rscript tests/erzeugen/engine_faelle.R "$out/cases" $ng 4711
  step "erzeugen Engine engine_stress.R ($ns)" "$out/gen_engine_stress.txt" Rscript tests/erzeugen/engine_stress.R "$out/stress" $ns 90210
fi

# 3. Bereiche erzeugen: Auswahl nach faelle/, alle Fälle nach faelle/alle/
gen=()
for m in "${mods[@]}"; do
  [[ -f tests/erzeugen/$m.R ]] || { note "FEHLER  Generator tests/erzeugen/$m.R fehlt"; status=1; continue; }
  step "erzeugen $m" "$out/gen_$m.txt" env SIMLEV_FAELLE_DIR="$out/faelle" SIMLEV_GEN_SUBSET=$sub SIMLEV_GEN_ALLE=1 \
       SIMLEV_GOLDEN_SRC="$out" Rscript "tests/erzeugen/$m.R" && gen+=("$m")
done

# 4. Python und Julia gegen alle neu erzeugten Fälle
cmp=()
for m in "${gen[@]}"; do [[ -f "$out/faelle/alle/$m.jsonl.gz" ]] && cmp+=("$out/faelle/alle/$m.jsonl.gz"); done
if ((${#cmp[@]})); then
  step "Python vergleich.py" "$out/py_ref.txt" python3 tests/gleichlauf/vergleich.py "${cmp[@]}"
  step "Julia vergleich.jl" "$out/jl_ref.txt" julia --project=julia tests/gleichlauf/vergleich.jl "${cmp[@]}"
fi

# 4b. R neu gegen den Katalog tests/faelle (Byte für Byte; sonst tests/erzeugen/alle.sh). Nur mit --full und allen
# Bereichen: In der Teilmenge (--quick) ziehen manche Generatoren ihre zufälligen Eingaben in anderer Folge.
if [[ $mode == full ]] && ((engine)); then
  step "R neu gegen tests/faelle (faelle_diff.py)" "$out/faelle_diff.txt" python3 -I tests/gleichlauf/faelle_diff.py "$out/faelle"
fi

# 5. Zufallsprüfungen (N11): Datumskern, slc_rbase-Kerne, Tarifkern, simulation(); R als Orakel
if ((engine)) || [[ $mode == full ]]; then
  fz="$out/fuzz"; rm -rf "$fz"; mkdir -p "$fz/date" "$fz/rbase"
  if step "erzeugen date_fuzz ($fz_date)" "$out/fz_date_gen.txt" Rscript tests/gleichlauf/date_fuzz.R "$fz/date" $fz_date; then
    step "Python date_fuzz" "$out/fz_date_py.txt" python3 tests/gleichlauf/date_fuzz_cmp.py "$fz/date"
    step "Julia date_fuzz" "$out/fz_date_jl.txt" julia --project=julia tests/gleichlauf/date_fuzz_cmp.jl "$fz/date"
  fi
  if step "erzeugen rbase_fuzz ($fz_rb je Kern)" "$out/fz_rbase_gen.txt" Rscript tests/gleichlauf/rbase_fuzz.R "$fz/rbase" $fz_rb; then
    step "Python rbase_fuzz" "$out/fz_rbase_py.txt" python3 tests/gleichlauf/rbase_fuzz_cmp.py "$fz/rbase"
    step "Julia rbase_fuzz" "$out/fz_rbase_jl.txt" julia --project=julia tests/gleichlauf/rbase_fuzz_cmp.jl "$fz/rbase"
  fi
  step "R tariff_fuzz ($fz_tt je Teil)" "$out/fz_tariff.txt" Rscript tests/gleichlauf/tariff_fuzz.R $fz_tt 20261101
  # E17: Zufallsfälle über simulation(); Referenz aus R 1.3.0 ist Pflicht (fehlt sie, scheitert der Schritt)
  reflib="${SIMLEV_FUZZ_REFLIB:-/home/claude/rlib130}"
  rm -rf "$fz/sim_ref" "$fz/sim_new"; mkdir -p "$fz/sim_ref" "$fz/sim_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  sim_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen sim_fuzz Referenz R 1.3.0 ($fz_sim)" "$out/fz_sim_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_FAELLE_DIR="$fz/sim_ref" Rscript tests/gleichlauf/sim_fuzz.R $fz_sim 20261101 \
     && step "erzeugen sim_fuzz R neu ($fz_sim)" "$out/fz_sim_new.txt" \
         env SIMLEV_FAELLE_DIR="$fz/sim_new" Rscript tests/gleichlauf/sim_fuzz.R $fz_sim 20261101; then
    step "Vergleich sim_fuzz R neu gegen R 1.3.0" "$out/fz_sim_r.txt" \
      python3 -I tests/gleichlauf/sim_fuzz_cmp.py "$fz/sim_ref/sim_fuzz.jsonl.gz" "$fz/sim_new/sim_fuzz.jsonl.gz"
    step "Python sim_fuzz gegen R 1.3.0" "$out/fz_sim_py.txt" python3 tests/gleichlauf/vergleich.py "$fz/sim_ref/sim_fuzz.jsonl.gz"
    step "Julia sim_fuzz gegen R 1.3.0" "$out/fz_sim_jl.txt" julia --project=julia tests/gleichlauf/vergleich.jl "$fz/sim_ref/sim_fuzz.jsonl.gz"
  fi
  # E17 Stufe 2: Datums-Fuzz der Vorbereitung (Termine, Kalender, Flags im Kern); Referenz aus R 1.3.0 (Pflicht)
  rm -rf "$fz/sched_ref" "$fz/sched_new"; mkdir -p "$fz/sched_ref" "$fz/sched_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  sched_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen sched_fuzz Referenz R 1.3.0 ($fz_sched)" "$out/fz_sched_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_FAELLE_DIR="$fz/sched_ref" Rscript tests/gleichlauf/sched_fuzz.R $fz_sched 20261102 \
     && step "erzeugen sched_fuzz R neu ($fz_sched)" "$out/fz_sched_new.txt" \
         env SIMLEV_FAELLE_DIR="$fz/sched_new" Rscript tests/gleichlauf/sched_fuzz.R $fz_sched 20261102; then
    step "Vergleich sched_fuzz R neu gegen R 1.3.0" "$out/fz_sched_r.txt" \
      python3 -I tests/gleichlauf/sim_fuzz_cmp.py "$fz/sched_ref/sched_fuzz.jsonl.gz" "$fz/sched_new/sched_fuzz.jsonl.gz"
    step "Python sched_fuzz gegen R 1.3.0" "$out/fz_sched_py.txt" python3 tests/gleichlauf/vergleich.py "$fz/sched_ref/sched_fuzz.jsonl.gz"
    step "Julia sched_fuzz gegen R 1.3.0" "$out/fz_sched_jl.txt" julia --project=julia tests/gleichlauf/vergleich.jl "$fz/sched_ref/sched_fuzz.jsonl.gz"
  fi
  # E17 Stufe 3: Fuzz der Kennzahlen (Auswertung im Kern); Referenz aus R 1.3.0 (Pflicht)
  rm -rf "$fz/metric_ref" "$fz/metric_new"; mkdir -p "$fz/metric_ref" "$fz/metric_new"
  if [[ ! -d "$reflib/SimLev" ]]; then
    note "FEHLER  metric_fuzz: Referenzbibliothek R 1.3.0 fehlt ($reflib; SIMLEV_FUZZ_REFLIB)"; status=1
  elif step "erzeugen metric_fuzz Referenz R 1.3.0 ($fz_met)" "$out/fz_metric_ref.txt" \
         env R_LIBS="$reflib" SIMLEV_FAELLE_DIR="$fz/metric_ref" Rscript tests/gleichlauf/metric_fuzz.R $fz_met 20261103 \
     && step "erzeugen metric_fuzz R neu ($fz_met)" "$out/fz_metric_new.txt" \
         env SIMLEV_FAELLE_DIR="$fz/metric_new" Rscript tests/gleichlauf/metric_fuzz.R $fz_met 20261103; then
    step "Vergleich metric_fuzz R neu gegen R 1.3.0" "$out/fz_metric_r.txt" \
      python3 -I tests/gleichlauf/sim_fuzz_cmp.py "$fz/metric_ref/metric_fuzz.jsonl.gz" "$fz/metric_new/metric_fuzz.jsonl.gz"
    step "Python metric_fuzz gegen R 1.3.0" "$out/fz_metric_py.txt" python3 tests/gleichlauf/vergleich.py "$fz/metric_ref/metric_fuzz.jsonl.gz"
    step "Julia metric_fuzz gegen R 1.3.0" "$out/fz_metric_jl.txt" julia --project=julia tests/gleichlauf/vergleich.jl "$fz/metric_ref/metric_fuzz.jsonl.gz"
  fi
fi

# 6. Abdeckung der Exporte durch den Katalog (Bericht; ohne Fall nur export_dashboard, schreibt eine Datei)
python3 tests/gleichlauf/exporte.py > "$out/exporte.txt" 2>&1
note "        $(head -n 1 "$out/exporte.txt")"

# 7. Zusammenfassung
note ""
for f in py_ref jl_ref; do
  [[ -f "$out/$f.txt" ]] || continue
  note "== $f"; grep -E "bitgleich|^Gesamt" "$out/$f.txt" | tee -a "$rep" > /dev/null
  grep -E "^Gesamt" "$out/$f.txt" | sed 's/^/   /'
done
for f in faelle_diff fz_date_py fz_date_jl fz_rbase_py fz_rbase_jl fz_tariff fz_sim_r fz_sim_py fz_sim_jl fz_sched_r fz_sched_py fz_sched_jl fz_metric_r fz_metric_py fz_metric_jl; do
  [[ -f "$out/$f.txt" ]] || continue
  note "== $f"; grep -E "textgleich|gleich$|gleich \(|^Gesamt|^GESAMT|^sim_fuzz|^[a-z0-9_]+ +[0-9]+ +[0-9]+/[0-9]+" "$out/$f.txt" | tee -a "$rep" > /dev/null
  grep -E "^Gesamt|^GESAMT" "$out/$f.txt" | sed 's/^/   /'
done
if ((status)); then note "Gleichlauf: ABWEICHUNG oder Fehler (siehe oben)"; else note "Gleichlauf: R, Python und Julia gleich"; fi
exit $status
