#!/usr/bin/env bash
# Schnittstellen-Abgleich in einem Befehl: drei Auszüge erzeugen, vergleichen,
# api.json und docs/STRUKTUR.md schreiben.
#   tools/api_snapshot/run.sh            Bericht, Rückgabewert 0
#   tools/api_snapshot/run.sh --check    Rückgabewert 1 bei nicht erklärten Abweichungen
#   tools/api_snapshot/run.sh -v --md x.md   weitere Optionen gehen an compare_api.py
set -euo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"
out="$here/out"
mkdir -p "$out"
Rscript "$here/api_r.R" "$out/api_r.json"
python3 "$here/api_py.py" "$out/api_py.json"
julia --project=julia "$here/api_jl.jl" "$out/api_jl.json"
status=0
python3 "$here/compare_api.py" --dir "$out" "$@" || status=$?
python3 "$here/make_struktur.py"
exit $status
