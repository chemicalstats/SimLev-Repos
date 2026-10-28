#!/usr/bin/env bash
# Messbasis: R, Python und Julia nacheinander messen (nie gleichzeitig), dann zusammenführen.
#   R_LIBS=<Bibliothek mit SimLev> tools/bench/run.sh [aufgaben]     z. B. T1,T8; Voreinstellung alle außer P1
#   R_LIBS=<…> tools/bench/run.sh P1     bootstrap mit cores = 1 und 2 (R/Python: Fork, Julia: -t 2)
# Ergebnis: tools/bench/out/{r,python,julia}.csv und tools/bench/ergebnis_<JJJJ-MM-TT>.csv
# (bei P1: out/*_parallel.csv und ergebnis_<JJJJ-MM-TT>_parallel.csv)
set -euo pipefail
export LC_ALL=C.UTF-8
# ein Kern: keine BLAS-/OpenMP-/Julia-Threads
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 JULIA_NUM_THREADS=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."
out="$here/out"; mkdir -p "$out"
tasks="${1:-}"
sfx=""
if [ "$tasks" = "P1" ]; then
  sfx="_parallel"
  export JULIA_NUM_THREADS=2    # cores = 2 braucht in Julia zwei Threads; BLAS bleibt bei einem
fi
Rscript "$here/bench.R" "$out/r$sfx.csv" $tasks
python3 "$here/bench.py" "$out/python$sfx.csv" $tasks
julia --project=julia "$here/bench.jl" "$out/julia$sfx.csv" $tasks
python3 "$here/merge.py" --out "$here/ergebnis_$(date +%F)$sfx.csv" --alt "$here/anhang_e_2026-10-20.csv" \
  "$out/r$sfx.csv" "$out/python$sfx.csv" "$out/julia$sfx.csv"
