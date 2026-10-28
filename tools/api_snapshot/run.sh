#!/usr/bin/env bash
# Schnittstellen-Abgleich in einem Befehl: drei Auszüge erzeugen, vergleichen,
# api.json und docs/STRUKTUR.md schreiben.
#   tools/api_snapshot/run.sh            Bericht, Rückgabewert 0
#   tools/api_snapshot/run.sh --check    Rückgabewert 1 bei nicht erklärten Abweichungen
#                                        oder bei Abweichung vom eingefrorenen Stand (frozen/)
#   tools/api_snapshot/run.sh --freeze   frozen/ neu schreiben; nur mit neuem Eintrag in CHANGES.md
#   tools/api_snapshot/run.sh -v --md x.md   weitere Optionen gehen an compare_api.py
set -euo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"
out="$here/out"
frozen="$here/frozen"
changes="$here/CHANGES.md"

check=0; freeze=0; pass=()
for a in "$@"; do
  case "$a" in
    --freeze) freeze=1 ;;
    --check) check=1; pass+=("$a") ;;
    *) pass+=("$a") ;;
  esac
done
if (( check && freeze )); then echo "run.sh: --check und --freeze nicht zusammen" >&2; exit 2; fi

# Stand der eingefrorenen Dateien (Feld "stand")
frozen_stand() { sed -n 's/^ "stand": "\(.*\)",$/\1/p' "$1" | head -n 1; }

# Neuester Eintrag in CHANGES.md: erste Überschrift "## JJJJ-MM-TT – Titel",
# darunter (bis zur nächsten Überschrift) "- Was: …" und "- Warum: …" mit Text.
newest_entry() {
  [[ -f "$changes" ]] || { echo "run.sh --freeze: $changes fehlt" >&2; return 1; }
  # Zeilen außerhalb von ```-Blöcken (die Vorlage oben in CHANGES.md zählt nicht)
  local text head
  text="$(awk '/^```/{f=!f; next} !f' "$changes")"
  head="$(grep -m 1 '^## ' <<< "$text" | sed 's/^## //')" || true
  [[ -n "$head" ]] || { echo "run.sh --freeze: kein Eintrag (\"## JJJJ-MM-TT – Titel\") in CHANGES.md" >&2; return 1; }
  if ! [[ "$head" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ (–|-)\ .+ ]] || ! date -d "${BASH_REMATCH[1]}" +%F > /dev/null 2>&1; then
    echo "run.sh --freeze: Überschrift \"## $head\" hat nicht die Form \"## JJJJ-MM-TT – Titel\"" >&2; return 1
  fi
  local body
  body="$(awk 'BEGIN{n=0} /^## /{n++; next} n==1' <<< "$text")"
  grep -Eq '^- Was: *[^ ]' <<< "$body" || { echo "run.sh --freeze: Eintrag \"## $head\" ohne \"- Was: …\"" >&2; return 1; }
  grep -Eq '^- Warum: *[^ ]' <<< "$body" || { echo "run.sh --freeze: Eintrag \"## $head\" ohne \"- Warum: …\"" >&2; return 1; }
  if (( $(grep -cxF "## $head" <<< "$text") > 1 )); then
    echo "run.sh --freeze: Überschrift \"## $head\" steht mehrfach in CHANGES.md" >&2; return 1
  fi
  printf '%s\n' "$head"
}

r_opt=(); py_opt=(); jl_opt=()
if (( freeze )); then
  stand="$(newest_entry)" || { echo "Abbruch: frozen/ bleibt unverändert. Erst einen Eintrag oben in tools/api_snapshot/CHANGES.md anlegen (Datum, was sich ändert, warum)." >&2; exit 1; }
  for f in r py jl; do
    if [[ -f "$frozen/$f.json" && "$(frozen_stand "$frozen/$f.json")" == "$stand" ]]; then
      echo "run.sh --freeze: frozen/$f.json hat schon den Stand \"$stand\"." >&2
      echo "Abbruch: frozen/ bleibt unverändert. Für eine neue Festschreibung erst einen neuen Eintrag oben in tools/api_snapshot/CHANGES.md anlegen (Datum, was sich ändert, warum)." >&2
      exit 1
    fi
  done
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  r_opt=(--frozen-out "$tmp/r.json" --stand "$stand")
  py_opt=(--frozen-out "$tmp/py.json" --stand "$stand")
  jl_opt=(--frozen-out "$tmp/jl.json" --stand "$stand")
elif (( check )); then
  r_opt=(--frozen-check "$frozen/r.json")
  py_opt=(--frozen-check "$frozen/py.json")
  jl_opt=(--frozen-check "$frozen/jl.json")
fi

mkdir -p "$out"
rm -f "$out"/api_r.json "$out"/api_py.json "$out"/api_jl.json
fstatus=0
Rscript "$here/api_r.R" "$out/api_r.json" "${r_opt[@]}" || fstatus=1
python3 "$here/api_py.py" "$out/api_py.json" "${py_opt[@]}" || fstatus=1
julia --project=julia "$here/api_jl.jl" "$out/api_jl.json" "${jl_opt[@]}" || fstatus=1

if (( freeze )); then
  (( fstatus == 0 )) || { echo "Abbruch: Auszug fehlgeschlagen, frozen/ bleibt unverändert." >&2; exit 1; }
  mkdir -p "$frozen"
  for f in r py jl; do
    if [[ -f "$frozen/$f.json" ]]; then diff -u --label "frozen/$f.json (alt)" --label "frozen/$f.json (neu)" "$frozen/$f.json" "$tmp/$f.json" || true; fi
    cp "$tmp/$f.json" "$frozen/$f.json"
  done
  echo "frozen/ neu festgeschrieben: Stand \"$stand\" (tools/api_snapshot/frozen/{r,py,jl}.json)"
fi

if (( check )); then
  # Der Stand in frozen/ muss ein Eintrag in CHANGES.md sein (nicht von Hand geändert)
  for f in r py jl; do
    [[ -f "$frozen/$f.json" ]] || continue
    s="$(frozen_stand "$frozen/$f.json")"
    if ! grep -qxF "## $s" "$changes" 2> /dev/null; then
      echo "frozen/$f.json: Stand \"$s\" steht nicht in CHANGES.md (frozen/ nur mit run.sh --freeze ändern)"; fstatus=1
    fi
  done
  if (( fstatus )); then echo "Eingefrorene Schnittstelle: ABWEICHUNG (siehe oben)"; else echo "Eingefrorene Schnittstelle: R, Python und Julia unverändert"; fi
fi

status=0
python3 "$here/compare_api.py" --dir "$out" "${pass[@]}" || status=$?
python3 "$here/make_struktur.py"
(( status == 0 )) && status=$fstatus
exit $status
