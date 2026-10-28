#!/usr/bin/env bash
# Messbasis: R, Python und Julia nacheinander messen (nie gleichzeitig), dann zusammenführen.
#   R_LIBS=<Bibliothek mit SimLev> tools/bench/run.sh [aufgaben]     z. B. T1,T8; Voreinstellung alle außer P1
#   R_LIBS=<…> tools/bench/run.sh P1     bootstrap mit cores = 1 und 2 (R/Python: Fork, Julia: -t 2)
#   R_LIBS=<…> tools/bench/run.sh --ohne-c T8   Python zusätzlich ohne C-Erweiterung (SIMLEV_NO_EXT=1,
#                                               Sprache "Python ohne C", out/python_ohne_c*.csv)
# Ergebnis: tools/bench/out/{r,python,julia}.csv und tools/bench/ergebnis_<JJJJ-MM-TT>.csv
# (bei P1: out/*_parallel.csv und ergebnis_<JJJJ-MM-TT>_parallel.csv)
set -euo pipefail
export LC_ALL=C.UTF-8
# ein Kern: keine BLAS-/OpenMP-/Julia-Threads
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 JULIA_NUM_THREADS=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."
out="$here/out"; mkdir -p "$out"
ohne_c=0
if [ "${1:-}" = "--ohne-c" ]; then ohne_c=1; shift; fi
tasks="${1:-}"
sfx=""
if [ "$tasks" = "P1" ]; then
  sfx="_parallel"
  export JULIA_NUM_THREADS=2    # cores = 2 braucht in Julia zwei Threads; BLAS bleibt bei einem
fi
Rscript "$here/bench.R" "$out/r$sfx.csv" $tasks
python3 "$here/bench.py" "$out/python$sfx.csv" $tasks
extra=()
if [ "$ohne_c" = 1 ]; then
  SIMLEV_NO_EXT=1 python3 "$here/bench.py" "$out/python_ohne_c$sfx.csv" $tasks
  extra=("$out/python_ohne_c$sfx.csv")
fi
julia --project=julia "$here/bench.jl" "$out/julia$sfx.csv" $tasks
python3 "$here/merge.py" --out "$here/ergebnis_$(date +%F)$sfx.csv" --alt "$here/anhang_e_2026-10-20.csv" \
  "$out/r$sfx.csv" "$out/python$sfx.csv" "${extra[@]}" "$out/julia$sfx.csv"
